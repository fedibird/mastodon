# frozen_string_literal: true

module HashtagUnification
  class FollowTagParity
    def call
      source = source_metrics
      target = target_metrics
      differences = difference_metrics

      {
        generated_at: Time.now.utc.iso8601,
        source: source,
        target: target,
        differences: differences,
        ok: parity_ok?(source, target, differences),
      }
    end

    private

    def connection
      ApplicationRecord.connection
    end

    def source_metrics
      row = connection.select_one(<<~SQL.squish)
        WITH relations AS (
          SELECT account_id, tag_id
          FROM follow_tags
          WHERE account_id IS NOT NULL AND tag_id IS NOT NULL
          GROUP BY account_id, tag_id
        ),
        destinations AS (
          SELECT
            account_id,
            tag_id,
            list_id,
            BOOL_AND(media_only) AS media_only
          FROM follow_tags
          WHERE account_id IS NOT NULL AND tag_id IS NOT NULL
          GROUP BY account_id, tag_id, list_id
        ),
        duplicate_destinations AS (
          SELECT
            account_id,
            tag_id,
            list_id,
            COUNT(*) AS row_count,
            COUNT(DISTINCT media_only) AS media_variants
          FROM follow_tags
          GROUP BY account_id, tag_id, list_id
          HAVING COUNT(*) > 1
        )
        SELECT
          (SELECT COUNT(*) FROM follow_tags) AS legacy_rows,
          (SELECT COUNT(*) FROM relations) AS expected_tag_follows,
          (SELECT COUNT(*) FROM destinations) AS expected_deliveries,
          (SELECT COUNT(*) FROM destinations WHERE list_id IS NULL) AS expected_home_deliveries,
          (SELECT COUNT(*) FROM destinations WHERE list_id IS NOT NULL) AS expected_list_deliveries,
          (SELECT COUNT(*) FROM duplicate_destinations) AS duplicate_destination_groups,
          (SELECT COUNT(*) FROM duplicate_destinations WHERE media_variants > 1) AS media_only_conflict_groups,
          (SELECT COUNT(*) FROM follow_tags WHERE account_id IS NULL OR tag_id IS NULL) AS null_account_or_tag_rows,
          (
            SELECT COUNT(*)
            FROM follow_tags ft
            LEFT JOIN lists l ON l.id = ft.list_id
            WHERE ft.list_id IS NOT NULL AND l.id IS NULL
          ) AS orphaned_list_rows,
          (
            SELECT COUNT(*)
            FROM follow_tags ft
            INNER JOIN lists l ON l.id = ft.list_id
            WHERE ft.list_id IS NOT NULL AND l.account_id <> ft.account_id
          ) AS list_owner_mismatches
      SQL

      integerize(row)
    end

    def target_metrics
      row = connection.select_one(<<~SQL.squish)
        SELECT
          (SELECT COUNT(*) FROM tag_follows) AS tag_follows,
          (SELECT COUNT(*) FROM tag_follow_deliveries) AS deliveries,
          (SELECT COUNT(*) FROM tag_follow_deliveries WHERE list_id IS NULL) AS home_deliveries,
          (SELECT COUNT(*) FROM tag_follow_deliveries WHERE list_id IS NOT NULL) AS list_deliveries,
          (
            SELECT COUNT(*)
            FROM tag_follows tf
            LEFT JOIN tag_follow_deliveries d ON d.tag_follow_id = tf.id
            WHERE d.id IS NULL
          ) AS tag_follows_without_deliveries,
          (
            SELECT COUNT(*)
            FROM tag_follow_deliveries d
            INNER JOIN tag_follows tf ON tf.id = d.tag_follow_id
            INNER JOIN lists l ON l.id = d.list_id
            WHERE d.list_id IS NOT NULL AND l.account_id <> tf.account_id
          ) AS list_owner_mismatches
      SQL

      integerize(row)
    end

    def difference_metrics
      relation_difference_metrics.merge(delivery_difference_metrics)
    end

    def relation_difference_metrics
      row = connection.select_one(<<~SQL.squish)
        WITH expected_relations AS (
          SELECT account_id, tag_id
          FROM follow_tags
          WHERE account_id IS NOT NULL AND tag_id IS NOT NULL
          GROUP BY account_id, tag_id
        )
        SELECT
          (
            SELECT COUNT(*)
            FROM expected_relations expected
            WHERE NOT EXISTS (
              SELECT 1
              FROM tag_follows actual
              WHERE actual.account_id = expected.account_id
                AND actual.tag_id = expected.tag_id
            )
          ) AS missing_tag_follows,
          (
            SELECT COUNT(*)
            FROM tag_follows actual
            WHERE NOT EXISTS (
              SELECT 1
              FROM expected_relations expected
              WHERE expected.account_id = actual.account_id
                AND expected.tag_id = actual.tag_id
            )
          ) AS extra_tag_follows
      SQL

      integerize(row)
    end

    def delivery_difference_metrics
      row = connection.select_one(<<~SQL.squish)
        WITH expected_destinations AS (
          SELECT
            account_id,
            tag_id,
            list_id,
            BOOL_AND(media_only) AS media_only
          FROM follow_tags
          WHERE account_id IS NOT NULL AND tag_id IS NOT NULL
          GROUP BY account_id, tag_id, list_id
        ),
        actual_destinations AS (
          SELECT
            tf.account_id,
            tf.tag_id,
            d.list_id,
            d.media_only
          FROM tag_follow_deliveries d
          INNER JOIN tag_follows tf ON tf.id = d.tag_follow_id
        )
        SELECT
          (
            SELECT COUNT(*)
            FROM expected_destinations expected
            WHERE NOT EXISTS (
              SELECT 1
              FROM actual_destinations actual
              WHERE actual.account_id = expected.account_id
                AND actual.tag_id = expected.tag_id
                AND actual.list_id IS NOT DISTINCT FROM expected.list_id
            )
          ) AS missing_deliveries,
          (
            SELECT COUNT(*)
            FROM actual_destinations actual
            WHERE NOT EXISTS (
              SELECT 1
              FROM expected_destinations expected
              WHERE expected.account_id = actual.account_id
                AND expected.tag_id = actual.tag_id
                AND expected.list_id IS NOT DISTINCT FROM actual.list_id
            )
          ) AS extra_deliveries,
          (
            SELECT COUNT(*)
            FROM expected_destinations expected
            INNER JOIN actual_destinations actual
              ON actual.account_id = expected.account_id
             AND actual.tag_id = expected.tag_id
             AND actual.list_id IS NOT DISTINCT FROM expected.list_id
            WHERE actual.media_only <> expected.media_only
          ) AS media_only_mismatches
      SQL

      integerize(row)
    end

    def parity_ok?(source, target, differences)
      source.values_at(:null_account_or_tag_rows, :orphaned_list_rows, :list_owner_mismatches).all?(&:zero?) &&
        target.values_at(:tag_follows_without_deliveries, :list_owner_mismatches).all?(&:zero?) &&
        differences.values.all?(&:zero?)
    end

    def integerize(row)
      row.to_h.symbolize_keys.transform_values(&:to_i)
    end
  end
end
