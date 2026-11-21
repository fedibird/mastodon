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

    # Hot path. The cached getter is false for both unset and explicit false.
    def effects_enabled?
      @user.setting_emoji_mute_enabled == true
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
      }
    end

    def update!(enabled)
      raise EmojiMutes::Invalid.new(KEY, 'invalid_type') unless [true, false].include?(enabled)

      changed = false
      EmojiMute.transaction do
        User.lock.find(@user.id)
        row = Setting.lock.find_by(thing_type: 'User', thing_id: @user.id, var: KEY)
        if row.nil?
          Setting.create!(thing_type: 'User', thing_id: @user.id, var: KEY, value: enabled)
          changed = true
        elsif row.value != enabled
          row.update!(value: enabled)
          changed = true
        end
      end
      forget_rules!
      self.class.publish!(@user, enabled) if changed
      as_json
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
    end
  end
end
