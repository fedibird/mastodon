# frozen_string_literal: true

module HashtagUnification
  class FollowTagMirror
    def initialize(account_id:, tag_id:)
      @account_id = account_id
      @tag_id = tag_id
    end

    def call
      return if account_id.nil? || tag_id.nil?

      tag_follow_id = upsert_tag_follow

      if tag_follow_id.nil?
        delete_tag_follow
        return
      end

      upsert_home_delivery(tag_follow_id)
      delete_stale_home_delivery(tag_follow_id)
      upsert_list_deliveries(tag_follow_id)
      delete_stale_list_deliveries(tag_follow_id)
    end

    private

    attr_reader :account_id, :tag_id

    def connection
      ApplicationRecord.connection
    end

    def quoted_account_id
      connection.quote(account_id)
    end

    def quoted_tag_id
      connection.quote(tag_id)
    end

    def upsert_tag_follow
      connection.select_value(<<~SQL.squish)&.to_i
        INSERT INTO tag_follows (account_id, tag_id, created_at, updated_at)
        SELECT
          account_id,
          tag_id,
          MIN(created_at),
          MAX(updated_at)
        FROM follow_tags
        WHERE account_id = #{quoted_account_id}
          AND tag_id = #{quoted_tag_id}
        GROUP BY account_id, tag_id
        ON CONFLICT (account_id, tag_id) DO UPDATE
        SET
          created_at = EXCLUDED.created_at,
          updated_at = EXCLUDED.updated_at
        RETURNING id
      SQL
    end

    def delete_tag_follow
      TagFollow.where(account_id: account_id, tag_id: tag_id).delete_all
    end

    def upsert_home_delivery(tag_follow_id)
      connection.execute(<<~SQL.squish)
        INSERT INTO tag_follow_deliveries (tag_follow_id, list_id, media_only, created_at, updated_at)
        SELECT
          #{connection.quote(tag_follow_id)},
          NULL,
          BOOL_AND(media_only),
          MIN(created_at),
          MAX(updated_at)
        FROM follow_tags
        WHERE account_id = #{quoted_account_id}
          AND tag_id = #{quoted_tag_id}
          AND list_id IS NULL
        HAVING COUNT(*) > 0
        ON CONFLICT (tag_follow_id) WHERE list_id IS NULL DO UPDATE
        SET
          media_only = EXCLUDED.media_only,
          created_at = EXCLUDED.created_at,
          updated_at = EXCLUDED.updated_at
      SQL
    end

    def delete_stale_home_delivery(tag_follow_id)
      connection.execute(<<~SQL.squish)
        DELETE FROM tag_follow_deliveries delivery
        WHERE delivery.tag_follow_id = #{connection.quote(tag_follow_id)}
          AND delivery.list_id IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM follow_tags source
            WHERE source.account_id = #{quoted_account_id}
              AND source.tag_id = #{quoted_tag_id}
              AND source.list_id IS NULL
          )
      SQL
    end

    def upsert_list_deliveries(tag_follow_id)
      connection.execute(<<~SQL.squish)
        INSERT INTO tag_follow_deliveries (tag_follow_id, list_id, media_only, created_at, updated_at)
        SELECT
          #{connection.quote(tag_follow_id)},
          list_id,
          BOOL_AND(media_only),
          MIN(created_at),
          MAX(updated_at)
        FROM follow_tags
        WHERE account_id = #{quoted_account_id}
          AND tag_id = #{quoted_tag_id}
          AND list_id IS NOT NULL
        GROUP BY list_id
        ON CONFLICT (tag_follow_id, list_id) WHERE list_id IS NOT NULL DO UPDATE
        SET
          media_only = EXCLUDED.media_only,
          created_at = EXCLUDED.created_at,
          updated_at = EXCLUDED.updated_at
      SQL
    end

    def delete_stale_list_deliveries(tag_follow_id)
      connection.execute(<<~SQL.squish)
        DELETE FROM tag_follow_deliveries delivery
        WHERE delivery.tag_follow_id = #{connection.quote(tag_follow_id)}
          AND delivery.list_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM follow_tags source
            WHERE source.account_id = #{quoted_account_id}
              AND source.tag_id = #{quoted_tag_id}
              AND source.list_id = delivery.list_id
          )
      SQL
    end
  end
end
