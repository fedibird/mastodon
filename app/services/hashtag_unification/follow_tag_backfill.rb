# frozen_string_literal: true

module HashtagUnification
  class FollowTagBackfill
    class UnsafeSourceDataError < StandardError; end

    SOURCE_BLOCKERS = %i(
      null_account_or_tag_rows
      orphaned_list_rows
      list_owner_mismatches
    ).freeze

    def initialize(apply: false, prune: false)
      @apply = apply
      @prune = prune
    end

    def call
      before = FollowTagParity.new.call
      assert_safe_source!(before.fetch(:source))

      return { mode: 'dry-run', prune: prune, before: before } unless apply

      writes = {}

      ApplicationRecord.transaction do
        writes[:cleared_legacy_follow_tag_ids] = execute(clear_reassigned_legacy_follow_tag_ids_sql)
        writes[:tag_follows] = execute(tag_follows_upsert_sql)
        writes[:home_deliveries] = execute(home_deliveries_upsert_sql)
        writes[:list_deliveries] = execute(list_deliveries_upsert_sql)

        if prune
          writes[:pruned_deliveries] = execute(prune_deliveries_sql)
          writes[:pruned_tag_follows] = execute(prune_tag_follows_sql)
        end
      end

      after = FollowTagParity.new.call

      {
        mode: 'APPLY',
        prune: prune,
        writes: writes,
        before: before,
        after: after,
      }
    end

    private

    attr_reader :apply, :prune

    def connection
      ApplicationRecord.connection
    end

    def assert_safe_source!(source)
      blockers = SOURCE_BLOCKERS.index_with { |key| source.fetch(key) }.reject { |_key, value| value.zero? }
      return if blockers.empty?

      raise UnsafeSourceDataError, "Refusing FollowTag backfill because source integrity checks failed: #{blockers.inspect}"
    end

    def execute(sql)
      result = connection.execute(sql)
      result.respond_to?(:cmd_tuples) ? result.cmd_tuples : nil
    end

    def clear_reassigned_legacy_follow_tag_ids_sql
      <<~SQL.squish
        UPDATE tag_follow_deliveries
        SET legacy_follow_tag_id = NULL
        WHERE legacy_follow_tag_id IN (
          SELECT MIN(id)
          FROM follow_tags
          WHERE account_id IS NOT NULL AND tag_id IS NOT NULL
          GROUP BY account_id, tag_id, list_id
        )
      SQL
    end

    def tag_follows_upsert_sql
      <<~SQL.squish
        INSERT INTO tag_follows (account_id, tag_id, created_at, updated_at)
        SELECT
          account_id,
          tag_id,
          MIN(created_at),
          MAX(updated_at)
        FROM follow_tags
        WHERE account_id IS NOT NULL AND tag_id IS NOT NULL
        GROUP BY account_id, tag_id
        ON CONFLICT (account_id, tag_id) DO UPDATE
        SET
          created_at = EXCLUDED.created_at,
          updated_at = EXCLUDED.updated_at
      SQL
    end

    def home_deliveries_upsert_sql
      <<~SQL.squish
        INSERT INTO tag_follow_deliveries (tag_follow_id, list_id, media_only, created_at, updated_at, legacy_follow_tag_id)
        SELECT
          target.id,
          NULL,
          BOOL_AND(source.media_only),
          MIN(source.created_at),
          MAX(source.updated_at),
          MIN(source.id)
        FROM follow_tags source
        INNER JOIN tag_follows target
          ON target.account_id = source.account_id
         AND target.tag_id = source.tag_id
        WHERE source.list_id IS NULL
        GROUP BY target.id
        ON CONFLICT (tag_follow_id) WHERE list_id IS NULL DO UPDATE
        SET
          media_only = EXCLUDED.media_only,
          created_at = EXCLUDED.created_at,
          updated_at = EXCLUDED.updated_at,
          legacy_follow_tag_id = EXCLUDED.legacy_follow_tag_id
      SQL
    end

    def list_deliveries_upsert_sql
      <<~SQL.squish
        INSERT INTO tag_follow_deliveries (tag_follow_id, list_id, media_only, created_at, updated_at, legacy_follow_tag_id)
        SELECT
          target.id,
          source.list_id,
          BOOL_AND(source.media_only),
          MIN(source.created_at),
          MAX(source.updated_at),
          MIN(source.id)
        FROM follow_tags source
        INNER JOIN tag_follows target
          ON target.account_id = source.account_id
         AND target.tag_id = source.tag_id
        WHERE source.list_id IS NOT NULL
        GROUP BY target.id, source.list_id
        ON CONFLICT (tag_follow_id, list_id) WHERE list_id IS NOT NULL DO UPDATE
        SET
          media_only = EXCLUDED.media_only,
          created_at = EXCLUDED.created_at,
          updated_at = EXCLUDED.updated_at,
          legacy_follow_tag_id = EXCLUDED.legacy_follow_tag_id
      SQL
    end

    def prune_deliveries_sql
      <<~SQL.squish
        DELETE FROM tag_follow_deliveries delivery
        USING tag_follows target
        WHERE delivery.tag_follow_id = target.id
          AND NOT EXISTS (
            SELECT 1
            FROM follow_tags source
            WHERE source.account_id = target.account_id
              AND source.tag_id = target.tag_id
              AND source.list_id IS NOT DISTINCT FROM delivery.list_id
          )
      SQL
    end

    def prune_tag_follows_sql
      <<~SQL.squish
        DELETE FROM tag_follows target
        WHERE NOT EXISTS (
          SELECT 1
          FROM follow_tags source
          WHERE source.account_id = target.account_id
            AND source.tag_id = target.tag_id
        )
      SQL
    end
  end
end
