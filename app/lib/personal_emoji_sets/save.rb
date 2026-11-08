# frozen_string_literal: true

class PersonalEmojiSets::Save
  FIELDS = %w(expected_revision expected_picker_emoji_size picker_emoji_size categories).freeze
  MAX_REVISION = (2**53) - 1

  def initialize(user)
    @user = user
  end

  def call(body)
    validate_body!(body)

    User.transaction do
      # Lock the existing user even on the first save. A lock on an absent set
      # cannot serialize two requests both trying to create revision 1.
      locked = lock_user
      record = PersonalEmojiSet.find_by(user_id: locked.id)
      size = PersonalEmojiSets::PickerSize.current(locked.id)
      revision = record&.revision || 0
      raise PersonalEmojiSets::Conflict unless revision == body['expected_revision'] && size == body['expected_picker_emoji_size']
      invalid!('expected_revision', 'revision_exhausted') if revision >= MAX_REVISION

      categories = PersonalEmojiSets::Definition.new(body['categories'], previous: record&.categories || []).validate!
      record ||= PersonalEmojiSet.new(user: locked)
      record.update!(categories: categories, revision: revision + 1)
      PersonalEmojiSets::PickerSize.write_legacy!(locked, body.fetch('picker_emoji_size').to_s) unless size == body['picker_emoji_size']

      PersonalEmojiSets::Document.new(revision: record.revision, categories: categories, picker_emoji_size: body.fetch('picker_emoji_size'))
    end
  end

  private

  def lock_user
    User.lock.find(@user.id)
  end

  def validate_body!(body)
    invalid!('body', 'invalid_type') unless body.is_a?(Hash)
    invalid!('body', 'unknown_field') unless (body.keys - FIELDS).empty?
    invalid!('expected_revision', 'invalid_revision') unless body['expected_revision'].is_a?(Integer) && body['expected_revision'].between?(0, MAX_REVISION)
    %w(expected_picker_emoji_size picker_emoji_size).each do |key|
      invalid!(key, 'invalid_size') unless body[key].is_a?(Integer) && PersonalEmojiSets::PickerSize::RANGE.cover?(body[key])
    end
  end

  def invalid!(path, code)
    raise PersonalEmojiSets::Invalid.new(path, code)
  end
end
