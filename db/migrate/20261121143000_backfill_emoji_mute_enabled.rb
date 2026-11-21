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
          SELECT DISTINCT emoji_mutes.user_id AS user_id
          FROM emoji_mutes
          WHERE NOT EXISTS (
            SELECT 1 FROM settings
            WHERE settings.thing_type = 'User'
              AND settings.thing_id = emoji_mutes.user_id
              AND settings.var = 'emoji_mute_enabled'
          )
        ) AS src
        ON CONFLICT (thing_type, thing_id, var) DO NOTHING
      SQL
    end
  end

  def down
    # created_at = updated_at is also true of a value the user saved and never
    # changed. A rollback cannot tell those rows from the ones this migration
    # inserted, so it leaves every emoji_mute_enabled row in place.
  end
end
