# frozen_string_literal: true

# Marks emoji reaction caches dirty with set-based SQL.
#
# An UPDATE always writes the flag, even when it is already true, so the
# statement takes the status_stats row lock. A refresh holding that lock
# cannot commit dirty=false and then lose a change that was waiting to mark
# the row dirty again.
class EmojiReactionCacheInvalidator
  class << self
    def mark_status!(status_id)
      sql = StatusStat.sanitize_sql_array([<<~SQL.squish, status_id: status_id])
        INSERT INTO status_stats (status_id, emoji_reactions_cache_dirty, created_at, updated_at)
        VALUES (:status_id, TRUE, LOCALTIMESTAMP, LOCALTIMESTAMP)
        ON CONFLICT (status_id) DO UPDATE
        SET emoji_reactions_cache_dirty = TRUE
      SQL

      StatusStat.connection.exec_update(sql, 'SQL')
    end

    def mark_for_custom_emoji_ids(custom_emoji_ids)
      ids = Array(custom_emoji_ids).map(&:to_i).uniq
      return 0 if ids.empty?

      sql = StatusStat.sanitize_sql_array([<<~SQL.squish, ids: ids])
        INSERT INTO status_stats (status_id, emoji_reactions_cache_dirty, created_at, updated_at)
        SELECT DISTINCT emoji_reactions.status_id, TRUE, LOCALTIMESTAMP, LOCALTIMESTAMP
        FROM emoji_reactions
        WHERE emoji_reactions.custom_emoji_id IN (:ids)
        ON CONFLICT (status_id) DO UPDATE
        SET emoji_reactions_cache_dirty = TRUE
      SQL

      StatusStat.connection.exec_update(sql, 'SQL')
    end

    # `relation` is an EmojiReaction scope, usually one delete_all batch.
    # Status ids stay in SQL; they are not loaded into a Ruby array.
    def mark_for_emoji_reactions(relation)
      subquery = relation.unscope(:select, :order, :includes).select(:status_id).distinct

      sql = <<~SQL.squish
        INSERT INTO status_stats (status_id, emoji_reactions_cache_dirty, created_at, updated_at)
        SELECT DISTINCT affected.status_id, TRUE, LOCALTIMESTAMP, LOCALTIMESTAMP
        FROM (#{subquery.to_sql}) AS affected
        ON CONFLICT (status_id) DO UPDATE
        SET emoji_reactions_cache_dirty = TRUE
      SQL

      StatusStat.connection.exec_update(sql, 'SQL')
    end
  end
end
