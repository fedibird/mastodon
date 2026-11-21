# frozen_string_literal: true

class BackfillEmojiMuteEnabled < ActiveRecord::Migration[6.1]
  # Users with at least one saved rule keep the feature on. Users with no
  # rules stay on the YAML default and get no settings row. A row that
  # already exists (explicit on or off) is left alone. The unique
  # (thing_type, thing_id, var) index makes a repeated run a no-op.
  def up
    value = connection.quote(true.to_yaml)
    safety_assured do
      execute(<<~SQL)
        INSERT INTO settings (var, value, thing_type, thing_id, created_at, updated_at)
        SELECT 'emoji_mute_enabled', #{value}, 'User', src.user_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM (
          SELECT DISTINCT emoji_mutes.user_id
          FROM emoji_mutes
          WHERE NOT EXISTS (
            SELECT 1 FROM settings
            WHERE settings.thing_type = 'User'
              AND settings.thing_id = emoji_mutes.user_id
              AND settings.var = 'emoji_mute_enabled'
          )
        ) AS src
      SQL
    end
  end

  def down
    safety_assured do
      execute(<<~SQL)
        DELETE FROM settings
        WHERE var = 'emoji_mute_enabled'
          AND thing_type = 'User'
          AND created_at = updated_at
          AND thing_id IN (SELECT DISTINCT user_id FROM emoji_mutes)
      SQL
    end
  end
end
