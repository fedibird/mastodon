# frozen_string_literal: true

require 'csv'
require 'json'
require 'tempfile'
require 'zlib'

module HashtagUnification
  class TagCanonicalizationPlanner
    class StaleCollisionManifestError < StandardError; end

    DEFAULT_BUCKET_COUNT = 64
    DEFAULT_BATCH_SIZE = 10_000
    DEFAULT_MAPPING_ROWS_PER_QUERY = 5_000

    TABLE_SPECS = {
      'statuses_tags' => { logical_keys: %w(status_id) },
      'accounts_tags' => { logical_keys: %w(account_id) },
      'featured_tags' => { logical_keys: %w(account_id), recount: true },
      'favourite_tags' => { logical_keys: %w(account_id) },
      'tag_account_mutes' => { logical_keys: %w(account_id) },
      'follow_tags' => { logical_keys: %w(account_id list_id), media_only: true, destination: true },
      'tag_follows' => { logical_keys: %w(account_id) },
    }.freeze

    def initialize(collision_manifest_path: nil, mapping_manifest_path: nil, bucket_count: DEFAULT_BUCKET_COUNT, batch_size: DEFAULT_BATCH_SIZE, mapping_rows_per_query: DEFAULT_MAPPING_ROWS_PER_QUERY)
      @collision_manifest_path = collision_manifest_path.presence
      @mapping_manifest_path = mapping_manifest_path.presence
      @bucket_count = bucket_count.to_i.clamp(1, 256)
      @batch_size = batch_size.to_i.clamp(100, 100_000)
      @mapping_rows_per_query = mapping_rows_per_query.to_i.clamp(100, 20_000)
      @normalizer = HashtagNormalizer.new
    end

    def call
      groups = collision_manifest_path ? groups_from_manifest : groups_from_database
      verify_manifest!(groups) if collision_manifest_path

      mapping_manifest = open_mapping_manifest
      write_mapping_manifest(mapping_manifest, groups) if mapping_manifest
      mapping_manifest&.close

      table_metrics = TABLE_SPECS.each_with_object({}) do |(table, spec), result|
        next unless analyzable_table?(table, spec)

        result[table] = relation_metrics(table, spec, groups)
      end

      {
        generated_at: Time.now.utc.iso8601,
        collision_source: collision_manifest_path || 'database_scan',
        mapping_manifest_path: mapping_manifest_path,
        collision_groups: groups.size,
        tags_in_collisions: groups.sum { |group| group[:members].size },
        losing_tags: groups.sum { |group| group[:members].size - 1 },
        survivor_selection: survivor_selection_counts(groups),
        table_metrics: table_metrics,
      }
    ensure
      mapping_manifest&.close unless mapping_manifest&.closed?
    end

    private

    attr_reader :collision_manifest_path, :mapping_manifest_path, :bucket_count, :batch_size, :mapping_rows_per_query, :normalizer

    def connection
      ApplicationRecord.connection
    end

    def groups_from_manifest
      CSV.foreach(collision_manifest_path, headers: true).map do |row|
        canonical_name = row.fetch('canonical_name')
        ids = JSON.parse(row.fetch('source_tag_ids')).map(&:to_i)
        names = JSON.parse(row.fetch('source_names'))

        unless ids.size == names.size && ids.size > 1
          raise StaleCollisionManifestError, "Malformed collision group for #{canonical_name.inspect}"
        end

        build_group(canonical_name, ids.zip(names).map { |id, name| { id: id, name: name } })
      end
    end

    def verify_manifest!(groups)
      expected = groups.flat_map { |group| group[:members] }.index_by { |member| member[:id] }
      actual = {}

      expected.keys.each_slice(1_000) do |ids|
        Tag.where(id: ids).pluck(:id, :name).each do |id, name|
          actual[id] = name
        end
      end

      missing_ids = expected.keys - actual.keys
      mismatched_ids = expected.each_with_object([]) do |(id, member), mismatches|
        next unless actual.key?(id)
        mismatches << id unless actual[id] == member[:name]
      end

      return if missing_ids.empty? && mismatched_ids.empty?

      raise StaleCollisionManifestError,
            "Collision manifest does not match this database: missing=#{missing_ids.size}, name_mismatches=#{mismatched_ids.size}"
    end

    def groups_from_database
      groups = []

      with_bucket_files do |files|
        Tag.select(:id, :name).find_in_batches(batch_size: batch_size) do |batch|
          batch.each do |tag|
            canonical_name = normalizer.normalize(tag.name)
            bucket = Zlib.crc32(canonical_name) % bucket_count
            files[bucket].puts(JSON.generate([canonical_name, tag.id, tag.name]))
          end
        end

        files.each(&:flush)

        files.each do |file|
          file.rewind
          bucket_groups = Hash.new { |hash, key| hash[key] = [] }

          file.each_line do |line|
            canonical_name, id, name = JSON.parse(line)
            bucket_groups[canonical_name] << { id: id.to_i, name: name }
          end

          bucket_groups.each do |canonical_name, members|
            groups << build_group(canonical_name, members) if members.size > 1
          end
        end
      end

      groups
    end

    def with_bucket_files
      files = Array.new(bucket_count) { Tempfile.new(['tag-canonicalization-plan', '.jsonl']) }
      yield files
    ensure
      files&.each(&:close!)
    end

    def build_group(canonical_name, members)
      members = members.sort_by { |member| member[:id] }
      survivor, reason = select_survivor(canonical_name, members)

      {
        canonical_name: canonical_name,
        survivor_id: survivor[:id],
        survivor_name: survivor[:name],
        survivor_reason: reason,
        members: members,
      }
    end

    def select_survivor(canonical_name, members)
      exact = members.select { |member| member[:name] == canonical_name }.min_by { |member| member[:id] }
      return [exact, :exact_canonical] if exact

      case_insensitive = members.select do |member|
        member[:name].mb_chars.casecmp(canonical_name.mb_chars).zero?
      end
      case_insensitive = case_insensitive.min_by { |member| member[:id] }
      return [case_insensitive, :case_insensitive_canonical] if case_insensitive

      [members.min_by { |member| member[:id] }, :lowest_id_fallback]
    end

    def survivor_selection_counts(groups)
      groups.group_by { |group| group[:survivor_reason] }.transform_values(&:size)
    end

    def analyzable_table?(table, spec)
      return false unless connection.data_source_exists?(table)

      column_names = connection.columns(table).map(&:name)
      (['tag_id'] + spec.fetch(:logical_keys)).all? { |column| column_names.include?(column) }
    end

    def relation_metrics(table, spec, groups)
      totals = default_relation_metrics(spec)

      each_group_chunk(groups) do |chunk|
        row = connection.select_one(relation_metrics_sql(table, spec, chunk))
        merge_metrics!(totals, row)
      end

      totals[:minimum_row_mutations] = totals[:rows_requiring_tag_id_change] + totals[:rows_to_delete_for_unique_result]
      totals[:recount_relationships] = totals[:affected_relationships] if spec[:recount]

      if spec[:destination]
        totals[:affected_parent_tag_follows] = affected_parent_tag_follows(table, groups)
      end

      totals
    end

    def default_relation_metrics(spec)
      metrics = {
        affected_relationships: 0,
        collision_group_rows: 0,
        losing_reference_rows: 0,
        survivor_reference_rows: 0,
        survivor_already_present_relationships: 0,
        rows_requiring_tag_id_change: 0,
        rows_to_delete_for_unique_result: 0,
        preexisting_survivor_extra_rows: 0,
      }

      metrics[:media_only_conflict_relationships] = 0 if spec[:media_only]
      metrics[:home_affected_relationships] = 0 if spec[:destination]
      metrics[:list_affected_relationships] = 0 if spec[:destination]
      metrics
    end

    def merge_metrics!(totals, row)
      row.to_h.each do |key, value|
        symbol = key.to_sym
        totals[symbol] = totals.fetch(symbol, 0) + value.to_i
      end
    end

    def relation_metrics_sql(table, spec, groups)
      keys = spec.fetch(:logical_keys)
      quoted_table = connection.quote_table_name(table)
      key_select = keys.map { |key| "source.#{connection.quote_column_name(key)}" }.join(', ')
      key_group = keys.map { |key| connection.quote_column_name(key) }.join(', ')
      media_select = spec[:media_only] ? ', source.media_only' : ''
      media_aggregate = spec[:media_only] ? ', COUNT(DISTINCT media_only) AS media_variants' : ''
      media_output = spec[:media_only] ? ', COUNT(*) FILTER (WHERE losing_rows > 0 AND media_variants > 1) AS media_only_conflict_relationships' : ''
      destination_output = if spec[:destination]
                             <<~SQL.squish
                               , COUNT(*) FILTER (WHERE losing_rows > 0 AND list_id IS NULL) AS home_affected_relationships
                               , COUNT(*) FILTER (WHERE losing_rows > 0 AND list_id IS NOT NULL) AS list_affected_relationships
                             SQL
                           else
                             ''
                           end

      <<~SQL.squish
        WITH mapping(old_tag_id, survivor_tag_id) AS (
          VALUES #{mapping_values(groups)}
        ),
        mapped AS (
          SELECT
            #{key_select},
            source.tag_id AS source_tag_id,
            mapping.survivor_tag_id
            #{media_select}
          FROM #{quoted_table} source
          INNER JOIN mapping ON mapping.old_tag_id = source.tag_id
        ),
        grouped AS (
          SELECT
            #{key_group},
            survivor_tag_id,
            COUNT(*) AS source_rows,
            COUNT(*) FILTER (WHERE source_tag_id <> survivor_tag_id) AS losing_rows,
            COUNT(*) FILTER (WHERE source_tag_id = survivor_tag_id) AS survivor_rows
            #{media_aggregate}
          FROM mapped
          GROUP BY #{key_group}, survivor_tag_id
        )
        SELECT
          COUNT(*) FILTER (WHERE losing_rows > 0) AS affected_relationships,
          COALESCE(SUM(source_rows) FILTER (WHERE losing_rows > 0), 0) AS collision_group_rows,
          COALESCE(SUM(losing_rows), 0) AS losing_reference_rows,
          COALESCE(SUM(survivor_rows) FILTER (WHERE losing_rows > 0), 0) AS survivor_reference_rows,
          COUNT(*) FILTER (WHERE losing_rows > 0 AND survivor_rows > 0) AS survivor_already_present_relationships,
          COUNT(*) FILTER (WHERE losing_rows > 0 AND survivor_rows = 0) AS rows_requiring_tag_id_change,
          COALESCE(SUM(source_rows - 1) FILTER (WHERE losing_rows > 0), 0) AS rows_to_delete_for_unique_result,
          COALESCE(SUM(GREATEST(survivor_rows - 1, 0)) FILTER (WHERE losing_rows > 0), 0) AS preexisting_survivor_extra_rows
          #{media_output}
          #{destination_output}
        FROM grouped
      SQL
    end

    def affected_parent_tag_follows(table, groups)
      total = 0

      each_group_chunk(groups) do |chunk|
        total += connection.select_value(<<~SQL.squish).to_i
          WITH mapping(old_tag_id, survivor_tag_id) AS (
            VALUES #{mapping_values(chunk)}
          ),
          mapped AS (
            SELECT
              source.account_id,
              source.tag_id AS source_tag_id,
              mapping.survivor_tag_id
            FROM #{connection.quote_table_name(table)} source
            INNER JOIN mapping ON mapping.old_tag_id = source.tag_id
          )
          SELECT COUNT(*)
          FROM (
            SELECT account_id, survivor_tag_id
            FROM mapped
            GROUP BY account_id, survivor_tag_id
            HAVING COUNT(*) FILTER (WHERE source_tag_id <> survivor_tag_id) > 0
          ) affected
        SQL
      end

      total
    end

    def each_group_chunk(groups)
      chunk = []
      row_count = 0

      groups.each do |group|
        group_rows = group[:members].size

        if chunk.any? && row_count + group_rows > mapping_rows_per_query
          yield chunk
          chunk = []
          row_count = 0
        end

        chunk << group
        row_count += group_rows
      end

      yield chunk if chunk.any?
    end

    def mapping_values(groups)
      groups.flat_map do |group|
        group[:members].map do |member|
          "(#{member[:id].to_i}, #{group[:survivor_id].to_i})"
        end
      end.join(', ')
    end

    def open_mapping_manifest
      return if mapping_manifest_path.nil?

      csv = CSV.open(mapping_manifest_path, 'wb')
      csv << %w(canonical_name old_tag_id old_name survivor_tag_id survivor_name survivor_reason is_survivor)
      csv
    end

    def write_mapping_manifest(csv, groups)
      groups.each do |group|
        group[:members].each do |member|
          csv << [
            group[:canonical_name],
            member[:id],
            member[:name],
            group[:survivor_id],
            group[:survivor_name],
            group[:survivor_reason],
            member[:id] == group[:survivor_id],
          ]
        end
      end
    end
  end
end
