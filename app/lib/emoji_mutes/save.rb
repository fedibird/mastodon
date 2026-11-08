# frozen_string_literal: true

# Creates, updates, and deletes the signed-in account's mute rules.
# Reads do not go through this object and do not write.
class EmojiMutes::Save
  CREATE_FIELDS = %w(emoji effects replacement).freeze
  UPDATE_FIELDS = %w(expected_revision effects replacement).freeze

  def create(account, body)
    fields!(body, CREATE_FIELDS)
    identity = EmojiMutes::Identity.for_create!(body['emoji'])
    effects = effects_for_create(body)
    replacement = replacement_for_create(body)
    mute = nil
    revision = nil
    EmojiMuteRevision.with_lock_for(account.id) do |state|
      raise_duplicate!(account.id, identity)
      raise_limit!(account.id)
      mute = EmojiMute.create!(identity.attributes.merge(account_id: account.id, revision: 1, replacement: replacement).merge(effects))
      revision = state.bump!
    end
    finish(account, revision)
    mute
  rescue ActiveRecord::RecordNotUnique
    raise EmojiMutes::Conflict.new('Emoji mute already exists', path: 'emoji', code: 'duplicate')
  end

  def update(account, mute, body, if_match:)
    fields!(body, UPDATE_FIELDS)
    expected = expected_revision(body)
    replacement = body.key?('replacement') ? replacement_value(body['replacement']) : nil
    effects = body.key?('effects') ? effects_patch(body['effects']) : {}
    revision = nil
    EmojiMuteRevision.with_lock_for(account.id) do |state|
      mute.lock!
      assert_revision!(mute, expected, if_match)
      mute.assign_attributes(effects)
      mute.replacement = replacement unless replacement.nil?
      mute.revision += 1
      mute.save!
      revision = state.bump!
    end
    finish(account, revision)
    mute
  end

  def destroy(account, mute, expected:, if_match:)
    revision = nil
    EmojiMuteRevision.with_lock_for(account.id) do |state|
      mute.lock!
      assert_revision!(mute, expected, if_match)
      mute.destroy!
      revision = state.bump!
    end
    finish(account, revision)
    revision
  end

  private

  def finish(account, revision)
    EmojiMutes::Current.forget(account.id)
    EmojiMutes::ChangeNotifier.new.publish(account, revision)
  end

  def raise_duplicate!(account_id, identity)
    return unless EmojiMute.matching_identity(account_id, identity).exists?

    raise EmojiMutes::Conflict.new('Emoji mute already exists', path: 'emoji', code: 'duplicate')
  end

  def raise_limit!(account_id)
    return if EmojiMute.where(account_id: account_id).count < EmojiMutes::MAX_PER_ACCOUNT

    raise EmojiMutes::Invalid.new('emoji', 'limit_reached')
  end

  def effects_for_create(body)
    return EmojiMutes::EFFECTS.index_with { true } unless body.key?('effects')

    patch = effects_patch(body['effects'])
    EmojiMutes::EFFECTS.index_with { |name| patch.fetch(name, true) }
  end

  def replacement_for_create(body)
    return EmojiMutes::DEFAULT_REPLACEMENT unless body.key?('replacement')

    replacement_value(body['replacement'])
  end

  def effects_patch(value)
    invalid!('effects', 'invalid_type') unless value.is_a?(Hash)
    invalid!('effects', 'unknown_field') unless (value.keys - EmojiMutes::EFFECTS).empty?

    value.each_with_object({}) do |(key, flag), memo|
      invalid!("effects.#{key}", 'invalid_boolean') unless [true, false].include?(flag)

      memo[key] = flag
    end
  end

  def replacement_value(value)
    invalid!('replacement', 'invalid_replacement') unless value.is_a?(String)
    invalid!('replacement', 'invalid_replacement') if value.include?("\u0000")
    invalid!('replacement', 'too_long') if value.scan(/\X/).length > EmojiMutes::MAX_REPLACEMENT_CHARS
    invalid!('replacement', 'too_long') if value.bytesize > EmojiMutes::MAX_REPLACEMENT_BYTES
    value
  end

  def expected_revision(body)
    invalid!('expected_revision', 'invalid_revision') unless body.key?('expected_revision')

    revision_number(body['expected_revision'])
  end

  def revision_number(value)
    invalid!('expected_revision', 'invalid_revision') unless value.is_a?(Integer)

    value
  end

  def assert_revision!(mute, expected, if_match)
    mismatch = mute.revision != expected
    mismatch ||= if_match.present? && !EmojiMutes::Etags.match?(if_match, EmojiMutes::Etags.item(mute))
    return unless mismatch

    raise EmojiMutes::Conflict.new('Revision conflict', path: 'expected_revision', code: 'conflict')
  end

  def fields!(body, allowed)
    invalid!('body', 'invalid_type') unless body.is_a?(Hash)
    invalid!('body', 'unknown_field') unless (body.keys - allowed).empty?
  end

  def invalid!(path, code)
    raise EmojiMutes::Invalid.new(path, code)
  end
end
