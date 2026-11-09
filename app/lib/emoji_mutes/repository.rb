# frozen_string_literal: true

module EmojiMutes
  class Repository
    CREATE_FIELDS = %w(emoji effects replacement).freeze
    UPDATE_FIELDS = %w(expected_revision effects replacement).freeze
    DELETE_FIELDS = %w(expected_revision).freeze

    def initialize(user)
      @user = user
    end

    def list
      mutes, revision = self.class.consistent_state(@user.id)
      Presenter.new(mutes).list(revision)
    end

    def revision
      self.class.consistent_state(@user.id).last
    end

    # User row lock, then both reads. A writer uses the same first lock, so
    # it cannot commit a new revision between the two selects.
    def self.consistent_state(user_id)
      EmojiMute.transaction do
        User.lock.find(user_id)
        mutes = EmojiMute.where(user_id: user_id).order(:id).to_a
        before_revision_read&.call
        revision = EmojiMuteCollection.where(user_id: user_id).pick(:revision) || 0
        [mutes, revision.to_i]
      end
    end

    def self.before_revision_read
      Thread.current[:emoji_mute_before_revision_read]
    end

    def self.before_revision_read=(callback)
      Thread.current[:emoji_mute_before_revision_read] = callback
    end

    def create(body)
      fields!(body, CREATE_FIELDS)
      invalid!('emoji', 'invalid_type') unless body['emoji'].is_a?(Hash)
      parsed = EmojiReferences::Parser.new.parse(body['emoji'])
      attributes = attributes_for(parsed)
      effects = effect_values(body['effects'], default: true)
      replacement = replacement_value(body.key?('replacement') ? body['replacement'] : EmojiMute::DEFAULT_REPLACEMENT)

      mute = nil
      revision = nil
      EmojiMute.transaction do
        collection = lock_collection!
        invalid!('emoji_mutes', 'limit_reached') if EmojiMute.where(user_id: @user.id).count >= EmojiMute::MAX_PER_USER

        mute = EmojiMute.create!(attributes.merge(effects).merge(user_id: @user.id, replacement: replacement, revision: 1))
        revision = bump!(collection)
      end
      publish!(revision)
      Presenter.new([mute]).one(mute, revision)
    rescue ActiveRecord::RecordNotUnique
      raise Conflict, 'duplicate'
    end

    def update(mute, body, if_match_revision: nil)
      fields!(body, UPDATE_FIELDS)
      effects = effect_values(body['effects'], default: nil)
      replacement = body.key?('replacement') ? replacement_value(body['replacement']) : nil
      revision = nil
      changed = false

      EmojiMute.transaction do
        locked = EmojiMute.lock.find_by!(id: mute.id, user_id: @user.id)
        assert_revision!(locked, body['expected_revision'], if_match_revision)
        changes = changes_for(locked, effects, replacement)
        mute = locked
        if changes.empty?
          revision = EmojiMuteCollection.where(user_id: @user.id).pick(:revision) || 0
        else
          collection = lock_collection!
          locked.update!(changes.merge(revision: locked.revision + 1))
          revision = bump!(collection)
          changed = true
        end
      end
      publish!(revision) if changed
      Presenter.new([mute]).one(mute, revision)
    end

    def destroy(mute, expected_revision:, if_match_revision:)
      revision = nil
      EmojiMute.transaction do
        locked = EmojiMute.lock.find_by!(id: mute.id, user_id: @user.id)
        assert_revision!(locked, expected_revision, if_match_revision)
        collection = lock_collection!
        locked.destroy!
        revision = bump!(collection)
      end
      publish!(revision)
      { 'revision' => revision.to_s }
    end

    private

    def attributes_for(parsed)
      if parsed.unicode?
        invalid!('emoji.native', 'invalid_unicode') unless PersonalEmojiSets::UnicodeCatalog.find(parsed.native)
        { kind: 'unicode', native: parsed.native, custom_emoji_id: nil, domain: nil, shortcode: nil }
      elsif parsed.remote?
        { kind: 'remote', native: nil, custom_emoji_id: nil, domain: parsed.domain, shortcode: parsed.shortcode }
      else
        record = local_record(parsed)
        invalid!('emoji.scope', 'contradictory_scope') unless record.local?
        invalid!('emoji.shortcode', 'contradictory_field') if parsed.shortcode && parsed.shortcode != record.shortcode
        { kind: 'local', native: nil, custom_emoji_id: record.id, domain: nil, shortcode: record.shortcode }
      end
    end

    def local_record(parsed)
      record = if parsed.custom_emoji_id
                 CustomEmoji.find_by(id: parsed.custom_emoji_id)
               else
                 CustomEmoji.local.find_by(shortcode: parsed.shortcode)
               end
      invalid!(parsed.custom_emoji_id ? 'emoji.custom_emoji_id' : 'emoji.shortcode', 'unavailable_emoji') unless record
      record
    end

    def effect_values(value, default:)
      return EmojiMute::EFFECTS.index_with { default } if value.nil? && default == true
      return {} if value.nil?

      invalid!('effects', 'invalid_type') unless value.is_a?(Hash)
      invalid!('effects', 'unknown_field') unless (value.keys - EmojiMute::EFFECTS).empty?
      value.each_with_object({}) do |(key, effect), effects|
        invalid!("effects.#{key}", 'invalid_type') unless [true, false].include?(effect)
        effects[key] = effect
      end
    end

    def replacement_value(value)
      invalid!('replacement', 'invalid_type') unless value.is_a?(String)
      invalid!('replacement', 'too_long') if value.bytesize > EmojiMute::MAX_REPLACEMENT_BYTES || value.scan(/\X/).size > EmojiMute::MAX_REPLACEMENT_GRAPHEMES
      invalid!('replacement', 'invalid_character') if value.match?(/[\u0000-\u001F\u007F]/)
      value
    end

    def changes_for(mute, effects, replacement)
      changes = {}
      effects.each do |key, value|
        changes[key] = value unless mute.public_send(key) == value
      end
      changes[:replacement] = replacement if !replacement.nil? && mute.replacement != replacement
      changes
    end

    def assert_revision!(mute, expected, if_match)
      invalid!('expected_revision', 'blank') if expected.nil? && if_match.nil?
      invalid!('expected_revision', 'invalid_type') if !expected.nil? && !expected.is_a?(String)
      invalid!('expected_revision', 'contradictory_field') if expected && if_match && expected != if_match
      current = mute.revision.to_s
      raise Conflict, 'conflict' if (expected && expected != current) || (if_match && if_match != current)
    end

    def fields!(body, allowed)
      invalid!('body', 'invalid_type') unless body.is_a?(Hash)
      invalid!('body', 'unknown_field') unless (body.keys - allowed).empty?
    end

    def lock_collection!
      User.lock.find(@user.id)
      collection = EmojiMuteCollection.lock.find_by(user_id: @user.id)
      collection ||= EmojiMuteCollection.create!(user_id: @user.id, revision: 0)
      collection
    end

    def bump!(collection)
      collection.update!(revision: collection.revision + 1)
      collection.revision
    end

    def publish!(revision)
      account_id = @user.account_id
      return if account_id.nil?

      payload = Oj.dump(event: 'emoji_mutes_changed', payload: { revision: revision.to_s })
      RedisConfiguration.with { |redis| redis.publish("timeline:#{account_id}", payload) }
    rescue Redis::BaseError, ConnectionPool::TimeoutError
      nil
    end

    def invalid!(path, code)
      raise Invalid.new(path, code)
    end
  end
end
