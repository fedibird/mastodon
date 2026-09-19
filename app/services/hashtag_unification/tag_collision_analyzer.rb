# frozen_string_literal: true

require 'csv'
require 'json'
require 'tempfile'
require 'zlib'

module HashtagUnification
  class TagCollisionAnalyzer
    DEFAULT_BUCKET_COUNT = 64
    DEFAULT_BATCH_SIZE = 10_000
    DEFAULT_TOP_LIMIT = 20
    REFERENCE_TABLES = %w(
      statuses_tags
      accounts_tags
      featured_tags
      favourite_tags
      tag_account_mutes
      follow_tags
      tag_follows
    ).freeze

    def initialize(manifest_path: nil, bucket_count: DEFAULT_BUCKET_COUNT, batch_size: DEFAULT_BATCH_SIZE, top_limit: DEFAULT_TOP_LIMIT)
      @manifest_path = manifest_path.presence
      @bucket_count = bucket_count.to_i.clamp(1, 256)
      @batch_size = batch_size.to_i.clamp(100, 100_000)
      @top_limit = top_limit.to_i.clamp(1, 100)
      @normalizer = HashtagNormalizer.new
    end

    def call
      stats = initial_stats
      collision_tag_ids = []
      largest_groups = []
      manifest = open_manifest

      with_bucket_files do |files|
        scan_tags(files, stats)
        process_buckets(files, stats, collision_tag_ids, largest_groups, manifest)
      end

      manifest&.close

      top_groups = largest_groups
                   .sort_by { |group| [-group[:size], group[:canonical_name]] }
                   .first(top_limit)
                   .map { |group| group.merge(reference_rows: reference_row_counts(group[:source_tag_ids])) }

      stats.merge(
        collision_reference_rows: reference_row_counts(collision_tag_ids),
        largest_collision_groups: top_groups,
        manifest_path: manifest_path
      )
    ensure
      manifest&.close unless manifest&.closed?
    end

    private

    attr_reader :manifest_path, :bucket_count, :batch_size, :top_limit, :normalizer

    def connection
      ApplicationRecord.connection
    end

    def initial_stats
      {
        generated_at: Time.now.utc.iso8601,
        total_tags: 0,
        already_canonical: 0,
        requiring_rename: 0,
        raw_display_name_rows: 0,
        invalid_raw_display_name_rows: 0,
        collision_groups: 0,
        tags_in_collisions: 0,
        largest_collision_size: 0,
      }
    end

    def with_bucket_files
      files = Array.new(bucket_count) { Tempfile.new(['hashtag-unification', '.jsonl']) }
      yield files
    ensure
      files&.each(&:close!)
    end

    def scan_tags(files, stats)
      columns = %i(id name)
      has_display_name = Tag.column_names.include?('display_name')
      columns << :display_name if has_display_name

      Tag.select(*columns).find_in_batches(batch_size: batch_size) do |batch|
        batch.each do |tag|
          canonical_name = normalizer.normalize(tag.name)
          raw_display_name = has_display_name ? tag.attributes['display_name'] : nil

          stats[:total_tags] += 1
          if tag.name == canonical_name
            stats[:already_canonical] += 1
          else
            stats[:requiring_rename] += 1
          end

          if raw_display_name.present?
            stats[:raw_display_name_rows] += 1
            stats[:invalid_raw_display_name_rows] += 1 unless normalizer.normalize(raw_display_name) == canonical_name
          end

          bucket = Zlib.crc32(canonical_name) % bucket_count
          files[bucket].puts(JSON.generate([canonical_name, tag.id, tag.name, raw_display_name]))
        end
      end

      files.each(&:flush)
    end

    def process_buckets(files, stats, collision_tag_ids, largest_groups, manifest)
      files.each do |file|
        file.rewind
        groups = Hash.new { |hash, key| hash[key] = [] }

        file.each_line do |line|
          canonical_name, id, name, display_name = JSON.parse(line)
          groups[canonical_name] << {
            id: id.to_i,
            name: name,
            display_name: display_name,
          }
        end

        groups.each do |canonical_name, members|
          next unless members.size > 1

          stats[:collision_groups] += 1
          stats[:tags_in_collisions] += members.size
          stats[:largest_collision_size] = [stats[:largest_collision_size], members.size].max
          collision_tag_ids.concat(members.map { |member| member[:id] })

          group = {
            canonical_name: canonical_name,
            size: members.size,
            source_tag_ids: members.map { |member| member[:id] }.sort,
            source_names: members.sort_by { |member| member[:id] }.map { |member| member[:name] },
          }

          largest_groups << group
          trim_largest_groups!(largest_groups)
          write_manifest_row(manifest, group) if manifest
        end
      end
    end

    def trim_largest_groups!(groups)
      return if groups.size <= top_limit * 2

      groups.sort_by! { |group| [-group[:size], group[:canonical_name]] }
      groups.slice!(top_limit, groups.length)
    end

    def open_manifest
      return if manifest_path.nil?

      csv = CSV.open(manifest_path, 'wb')
      csv << %w(canonical_name source_tag_ids source_names)
      csv
    end

    def write_manifest_row(manifest, group)
      manifest << [
        group[:canonical_name],
        JSON.generate(group[:source_tag_ids]),
        JSON.generate(group[:source_names]),
      ]
    end

    def reference_row_counts(tag_ids)
      counts = {}
      return counts if tag_ids.empty?

      REFERENCE_TABLES.each do |table|
        next unless connection.data_source_exists?(table)
        next unless connection.columns(table).any? { |column| column.name == 'tag_id' }

        counts[table] = tag_ids.each_slice(1_000).sum do |ids|
          connection.select_value(<<~SQL.squish).to_i
            SELECT COUNT(*)
            FROM #{connection.quote_table_name(table)}
            WHERE tag_id IN (#{ids.join(',')})
          SQL
        end
      end

      counts
    end
  end
end
