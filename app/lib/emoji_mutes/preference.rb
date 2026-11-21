# frozen_string_literal: true

module EmojiMutes
  # Feature switch, separate from emoji_mute_disable_actions.
  #
  # Unset uses the settings.yml default (off) and is not an explicit choice.
  # An explicit false must not be turned back on by saving a rule unless the
  # request says enable: true. Deleting the last rule does not write this row.
  class Preference
    KEY = 'emoji_mute_enabled'
    MODAL_KEY = 'emoji_mute_modal'

    def initialize(user)
      @user = user
    end

    def record
      Setting.unscoped.find_by(thing_type: 'User', thing_id: @user.id, var: KEY)
    end

    def modal_record
      Setting.unscoped.find_by(thing_type: 'User', thing_id: @user.id, var: MODAL_KEY)
    end

    def explicit?
      !record.nil?
    end

    def enabled?
      record&.value == true
    end

    # The settings cache can be filled by a read that started before a newer
    # commit. Reaction rejection uses the row, remembered for this request.
    def effects_enabled?
      self.class.read_value(@user) == true
    end

    def self.read_value(user)
      flags = EmojiMutes::Store.effect_flags
      return flags[user.id] if flags&.key?(user.id)

      row = Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: KEY)
      value = row ? row.value : false
      (EmojiMutes::Store.effect_flags ||= {})[user.id] = value
      value
    end

    def modal?
      row = modal_record
      return true if row.nil?

      row.value != false
    end

    def as_json
      {
        'enabled' => enabled?,
        'explicit' => explicit?,
        'known' => true,
        'modal' => modal?,
        'preference_revision' => self.class.revision_of(record),
      }
    end

    def self.revision_of(row)
      return '0' if row.nil? || row.updated_at.nil?

      format('%d', (row.updated_at.to_r * 1_000_000).round)
    end

    # Fields for the rules list. The caller already loaded this row under the
    # user lock, so the list does not read the switch again.
    def self.list_json(row)
      {
        'enabled' => row&.value == true,
        'explicit' => !row.nil?,
        'known' => true,
        'preference_revision' => revision_of(row),
      }
    end

    def update!(enabled)
      raise EmojiMutes::Invalid.new(KEY, 'invalid_type') unless [true, false].include?(enabled)

      changed = false
      revision = '0'
      EmojiMute.transaction do
        User.lock.find(@user.id)
        row = Setting.lock.find_by(thing_type: 'User', thing_id: @user.id, var: KEY)
        if row.nil?
          row = Setting.create!(thing_type: 'User', thing_id: @user.id, var: KEY, value: enabled)
          changed = true
        elsif row.value != enabled
          row.update!(value: enabled)
          changed = true
        end
        revision = self.class.revision_of(row)
      end
      forget_rules!
      self.class.publish!(@user, enabled) if changed
      as_json.merge('enabled' => enabled, 'explicit' => true, 'preference_revision' => revision)
    end

    # Inside the mute-create transaction. The caller already holds User.lock.
    # A later statement in that transaction must be able to roll this write back.
    def enable_for_registration!(explicit_enable:)
      row = Setting.lock.find_by(thing_type: 'User', thing_id: @user.id, var: KEY)
      if row.nil?
        Setting.create!(thing_type: 'User', thing_id: @user.id, var: KEY, value: true)
        return :enabled
      end

      return :already if row.value == true

      raise EmojiMutes::Invalid.new(KEY, 'reenable_required') unless explicit_enable == true

      row.update!(value: true)
      :enabled
    end

    # A committed value can be older than another commit by the time this
    # callback runs. Re-read under the same user lock the writers take, and
    # store that row. Writing the in-memory value here would republish it.
    def self.refresh_cache(record)
      User.transaction do
        User.lock.find_by(id: record.thing_id)
        latest = Setting.unscoped.find_by(thing_type: 'User', thing_id: record.thing_id, var: KEY)
        if latest
          Rails.cache.write(record.cache_key, latest.value)
        else
          Rails.cache.delete(record.cache_key)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("Emoji mute preference cache refresh failed user_id=#{record.thing_id} error=#{e.class}")
    end

    def self.publish!(user, enabled)
      account_id = user.account_id
      return if account_id.nil?

      payload = Oj.dump(event: 'emoji_mute_preference', payload: { 'enabled' => enabled == true })
      RedisConfiguration.with { |redis| redis.publish("timeline:#{account_id}", payload) }
    rescue Redis::BaseError, ConnectionPool::TimeoutError
      nil
    end

    def forget_rules!
      EmojiMutes::Store.rule_sets&.delete(@user.id)
      EmojiMutes::Store.effect_flags&.delete(@user.id)
    end
  end
end
