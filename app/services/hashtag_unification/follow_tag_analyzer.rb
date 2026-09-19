# frozen_string_literal: true

module HashtagUnification
  class FollowTagAnalyzer
    DEFAULT_SAMPLE_LIMIT = 20

    def initialize(sample_limit: DEFAULT_SAMPLE_LIMIT)
      @sample_limit = sample_limit.to_i.clamp(0, 100)
    end

    def call
      {
        generated_at: Time.now.utc.iso8601,
        source_table: 'follow_tags',
        totals: totals,
        relation_shapes: relation_shapes,
        duplicates: duplicates,
        integrity: integrity,
        delivery_count_distribution: delivery_count_distribution,
        duplicate_examples: duplicate_examples,
      }
    end

    private

    attr_reader :sample_limit

    def connection
      ApplicationRecord.connection
    end

    def totals
      {
        rows: FollowTag.count,
        home_rows: FollowTag.where(list_id: nil).count,
        list_rows: FollowTag.where.not(list_id: nil).count,
      }
    end

    def relation_shapes
      row = connection.select_one(<<~SQL.squish)
        WITH grouped AS (
          SELECT
            account_id,
            tag_id,
            COUNT(*) FILTER (WHERE list_id IS NULL) AS home_rows,
            COUNT(*) FILTER (WHERE list_id IS NOT NULL) AS list_rows,
            COUNT(DISTINCT list_id) FILTER (WHERE list_id IS NOT NULL) AS list_destinations
          FROM follow_tags
          GROUP BY account_id, tag_id
        )
        SELECT
          COUNT(*) AS distinct_relations,
          COUNT(*) FILTER (WHERE home_rows > 0 AND list_rows = 0) AS home_only_relations,
          COUNT(*) FILTER (WHERE home_rows = 0 AND list_rows > 0) AS lists_only_relations,
          COUNT(*) FILTER (WHERE home_rows > 0 AND list_rows > 0) AS home_and_lists_relations,
          COUNT(*) FILTER (WHERE list_destinations > 1) AS multi_list_relations,
          COALESCE(MAX((CASE WHEN home_rows > 0 THEN 1 ELSE 0 END) + list_destinations), 0) AS max_destinations
        FROM grouped
      SQL

      integerize(row)
    end

    def duplicates
      row = connection.select_one(<<~SQL.squish)
        WITH grouped AS (
          SELECT
            account_id,
            tag_id,
            list_id,
            COUNT(*) AS row_count,
            COUNT(DISTINCT media_only) AS media_variants
          FROM follow_tags
          GROUP BY account_id, tag_id, list_id
        )
        SELECT
          COUNT(*) FILTER (WHERE row_count > 1) AS duplicate_destination_groups,
          COALESCE(SUM(row_count - 1) FILTER (WHERE row_count > 1), 0) AS duplicate_extra_rows,
          COUNT(*) FILTER (WHERE row_count > 1 AND media_variants > 1) AS media_only_conflict_groups
        FROM grouped
      SQL

      integerize(row)
    end

    def integrity
      row = connection.select_one(<<~SQL.squish)
        SELECT
          COUNT(*) FILTER (WHERE accounts.id IS NULL) AS orphaned_accounts,
          COUNT(*) FILTER (WHERE tags.id IS NULL) AS orphaned_tags,
          COUNT(*) FILTER (WHERE follow_tags.list_id IS NOT NULL AND lists.id IS NULL) AS orphaned_lists
        FROM follow_tags
        LEFT JOIN accounts ON accounts.id = follow_tags.account_id
        LEFT JOIN tags ON tags.id = follow_tags.tag_id
        LEFT JOIN lists ON lists.id = follow_tags.list_id
      SQL

      integerize(row)
    end

    def delivery_count_distribution
      rows = connection.select_all(<<~SQL.squish)
        WITH grouped AS (
          SELECT
            account_id,
            tag_id,
            (CASE WHEN COUNT(*) FILTER (WHERE list_id IS NULL) > 0 THEN 1 ELSE 0 END) +
              COUNT(DISTINCT list_id) FILTER (WHERE list_id IS NOT NULL) AS destinations
          FROM follow_tags
          GROUP BY account_id, tag_id
        )
        SELECT destinations, COUNT(*) AS relations
        FROM grouped
        GROUP BY destinations
        ORDER BY destinations
      SQL

      rows.map do |row|
        {
          destinations: row['destinations'].to_i,
          relations: row['relations'].to_i,
        }
      end
    end

    def duplicate_examples
      return [] if sample_limit.zero?

      rows = connection.select_all(<<~SQL.squish)
        SELECT
          account_id,
          tag_id,
          list_id,
          COUNT(*) AS row_count,
          ARRAY_AGG(DISTINCT media_only ORDER BY media_only) AS media_only_values
        FROM follow_tags
        GROUP BY account_id, tag_id, list_id
        HAVING COUNT(*) > 1
        ORDER BY COUNT(*) DESC, account_id, tag_id, list_id NULLS FIRST
        LIMIT #{sample_limit}
      SQL

      rows.map do |row|
        {
          account_id: row['account_id'].to_i,
          tag_id: row['tag_id'].to_i,
          list_id: row['list_id']&.to_i,
          row_count: row['row_count'].to_i,
          media_only_values: parse_postgres_boolean_array(row['media_only_values']),
        }
      end
    end

    def integerize(row)
      row.to_h.symbolize_keys.transform_values { |value| value.to_i }
    end

    def parse_postgres_boolean_array(value)
      return [] if value.blank?

      value.delete_prefix('{').delete_suffix('}').split(',').map { |item| item == 't' }
    end
  end
end
