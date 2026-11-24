# frozen_string_literal: true

# Remove one typed emoji from one existing category. The user-row lock and
# revision comparison match PersonalEmojiSets::AddItem and Save. Identity is
# the finished Unicode string or the local custom emoji database id. A
# shortcode or image URL is never sufficient. Other categories, placement
# order, unavailable rows, and the picker size stay in place. Removing the
# representative placement falls back to the editor's first-emoji heading.
class PersonalEmojiSets::RemoveItem
  FIELDS = %w(expected_revision emoji).freeze

  Result = Struct.new(:document, :removed, :category_id, :item_ids, keyword_init: true) do
    def as_json(*)
      document.as_json.merge(operation: { removed: removed, category_id: category_id, item_ids: item_ids })
    end
  end

  def initialize(user)
    @user = user
  end

  def call(body, category_id:)
    validate_envelope!(body)
    @parsed = EmojiReferences::Parser.new.parse(body.fetch('emoji'))
    require_custom_identity!
    @category_id = category_id

    User.transaction do
      @locked = lock_user
      @record = PersonalEmojiSet.find_by(user_id: @locked.id)
      @revision = @record&.revision || 0
      raise PersonalEmojiSets::Conflict unless @revision == body['expected_revision']
      invalid!('expected_revision', 'revision_exhausted') if @revision >= PersonalEmojiSets::Save::MAX_REVISION

      @categories = (@record&.categories || []).deep_dup
      @category = find_category
      matches = matching_items
      if matches.empty?
        unchanged_result
      else
        assert_shortcode!(matches)
        remove_result(matches)
      end
    end
  end

  private

  def lock_user
    User.lock.find(@user.id)
  end

  def validate_envelope!(body)
    invalid!('body', 'invalid_type') unless body.is_a?(Hash)
    invalid!('body', 'unknown_field') unless (body.keys - FIELDS).empty?
    revision = body['expected_revision']
    invalid!('expected_revision', 'invalid_revision') unless revision.is_a?(Integer) && revision.between?(0, PersonalEmojiSets::Save::MAX_REVISION)
    invalid!('emoji', 'invalid_type') unless body['emoji'].is_a?(Hash)
  end

  # Local removal follows the database id used by referencesEqual. A shortcode
  # alone could name a later emoji that reused it, so it is rejected.
  def require_custom_identity!
    return if @parsed.unicode? || @parsed.remote?
    return if @parsed.custom_emoji_id.present?

    invalid!('emoji.custom_emoji_id', 'identity_required')
  end

  def find_category
    valid_id = @category_id.is_a?(String) && PersonalEmojiSets::Definition::ID_PATTERN.match?(@category_id)
    category = @categories.find { |entry| entry['id'] == @category_id } if valid_id
    raise PersonalEmojiSets::CategoryNotFound unless category

    category
  end

  def matching_items
    items = @category.fetch('items')
    if @parsed.unicode?
      items.select { |item| item['kind'] == 'unicode' && item['native'] == @parsed.native }
    elsif @parsed.remote?
      []
    else
      items.select { |item| item['kind'] == 'custom' && item['custom_emoji_id'] == @parsed.custom_emoji_id }
    end
  end

  def assert_shortcode!(matches)
    return if @parsed.shortcode.nil?

    record = CustomEmoji.find_by(id: @parsed.custom_emoji_id)
    matches.each do |item|
      next if item['shortcode'] == @parsed.shortcode
      next if record&.shortcode == @parsed.shortcode

      invalid!('emoji.shortcode', 'contradictory_field')
    end
  end

  def remove_result(matches)
    removed_ids = matches.map { |item| item.fetch('id') }
    @category['items'] = @category.fetch('items').reject { |item| removed_ids.include?(item['id']) }
    heading = @category['heading']
    if heading.is_a?(Hash) && heading['mode'] == 'emoji' && removed_ids.include?(heading['item_id'])
      @category['heading'] = { 'mode' => 'first' }
    end

    validated = PersonalEmojiSets::Definition.new(@categories, previous: @record&.categories || []).validate!
    @record.update!(categories: validated, revision: @revision + 1)
    result_for(@record.revision, validated, removed_ids, removed: true)
  end

  def unchanged_result
    result_for(@revision, @record&.categories || [], [], removed: false)
  end

  def result_for(revision, categories, item_ids, removed:)
    document = PersonalEmojiSets::Document.new(
      revision: revision,
      categories: categories,
      picker_emoji_size: PersonalEmojiSets::PickerSize.current(@locked.id)
    )
    Result.new(document: document, removed: removed, category_id: @category_id, item_ids: item_ids)
  end

  def invalid!(path, code)
    raise EmojiReferences::Invalid.new(path, code)
  end
end
