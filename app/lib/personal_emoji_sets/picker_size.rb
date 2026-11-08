# frozen_string_literal: true

# Keep the existing scalar settings row and its legacy string representation.
# It is not part of the personal-set JSON or UserPreferences' public keys.
class PersonalEmojiSets::PickerSize
  KEY = 'picker_emoji_size'
  RANGE = (22..48).freeze
  DEFAULT = 22

  class << self
    def read_raw(user_id)
      row = records(user_id).first
      row ? row.value : Setting.default_settings[KEY]
    end

    def current(user_id)
      value = read_raw(user_id)
      number = value.is_a?(Integer) ? value : value.to_s.match?(/\A[0-9]+\z/) && value.to_i
      number.is_a?(Integer) && RANGE.cover?(number) ? number : DEFAULT
    end

    # The editor validates its integer range before calling this. Legacy
    # Rails settings inputs retain their existing raw-value behavior, but
    # share the user lock and after-commit cache path with the editor.
    def write_legacy!(user, value)
      User.transaction do
        locked = User.lock.find(user.id)
        row = records(locked.id).first_or_initialize
        row.value = value
        row.save!
      end
      value
    end

    def refresh_cache(record)
      User.transaction do
        User.lock.find_by(id: record.thing_id)
        latest = records(record.thing_id).first
        if latest
          Rails.cache.write(record.cache_key, latest.value)
        else
          Rails.cache.delete(record.cache_key)
        end
      end
    rescue StandardError => e
      # The database commit already succeeded. A cache outage must not turn
      # it into an apparent failed save that the editor would try to replay.
      Rails.logger.warn("Personal emoji picker size cache refresh failed user_id=#{record.thing_id} error=#{e.class}")
    end

    private

    def records(user_id)
      Setting.unscoped.where(thing_type: 'User', thing_id: user_id, var: KEY)
    end
  end
end
