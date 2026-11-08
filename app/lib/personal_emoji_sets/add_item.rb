# frozen_string_literal: true

# Append one emoji to an existing category. The user-row lock and revision
# comparison match PersonalEmojiSets::Save. Revision is compared before
# duplicate detection and before emoji availability.
class PersonalEmojiSets::AddItem
  FIELDS = %w(expected_revision emoji).freeze

  Result = Struct.new(:document, :added, :category_id, :item_id, keyword_init: true) do
    def as_json(*)
      document.as_json.merge(operation: { added: added, category_id: category_id, item_id: item_id })
    end
  end

  def initialize(user)
    @user = user
  end

  def call(body, category_id:)
    validate_envelope!(body)
    @parsed = EmojiReferences::Parser.new.parse(body.fetch('emoji'))
    @category_id = category_id

    User.transaction do
      @locked = lock_user
      @record = PersonalEmojiSet.find_by(user_id: @locked.id)
      @revision = @record&.revision || 0
      raise PersonalEmojiSets::Conflict unless @revision == body['expected_revision']
      invalid!('expected_revision', 'revision_exhausted') if @revision >= PersonalEmojiSets::Save::MAX_REVISION

      @categories = (@record&.categories || []).deep_dup
      @category = find_category
      existing = duplicate_item
      existing ? unchanged_result(existing.fetch('id')) : append_result
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

  def find_category
    valid_id = @category_id.is_a?(String) && PersonalEmojiSets::Definition::ID_PATTERN.match?(@category_id)
    category = @categories.find { |entry| entry['id'] == @category_id } if valid_id
    raise PersonalEmojiSets::CategoryNotFound unless category

    category
  end

  def duplicate_item
    return unicode_duplicate if @parsed.unicode?
    return nil if @parsed.remote?

    if @parsed.custom_emoji_id
      found = @category.fetch('items').find { |item| item['kind'] == 'custom' && item['custom_emoji_id'] == @parsed.custom_emoji_id }
      ensure_shortcode!(found) if found
      found
    else
      record = CustomEmoji.local.find_by(shortcode: @parsed.shortcode)
      return nil unless record

      @category.fetch('items').find { |item| item['custom_emoji_id'] == record.id.to_s }
    end
  end

  def unicode_duplicate
    @category.fetch('items').find { |item| item['kind'] == 'unicode' && item['native'] == @parsed.native }
  end

  def ensure_shortcode!(existing)
    return if @parsed.shortcode.nil?

    record = CustomEmoji.find_by(id: @parsed.custom_emoji_id)
    expected = record&.shortcode || existing.fetch('shortcode')
    invalid!('emoji.shortcode', 'contradictory_field') if @parsed.shortcode != expected
  end

  def append_result
    item = new_item
    @category['items'] = @category.fetch('items') + [item]
    validated = PersonalEmojiSets::Definition.new(@categories, previous: @record&.categories || []).validate!
    stored = @record || PersonalEmojiSet.new(user: @locked)
    stored.update!(categories: validated, revision: @revision + 1)
    result_for(stored.revision, validated, item.fetch('id'), added: true)
  end

  def new_item
    id = generate_id
    return unicode_item(id) if @parsed.unicode?
    invalid!('emoji', 'remote_emoji') if @parsed.remote?

    record = addable_local!
    { 'id' => id, 'kind' => 'custom', 'custom_emoji_id' => record.id.to_s, 'shortcode' => record.shortcode }
  end

  def unicode_item(id)
    emoji = PersonalEmojiSets::UnicodeCatalog.find(@parsed.native)
    invalid!('emoji.native', 'invalid_unicode') unless emoji

    { 'id' => id, 'kind' => 'unicode', 'native' => @parsed.native, 'emoji_id' => emoji.fetch(:id) }
  end

  def addable_local!
    record = if @parsed.custom_emoji_id
               CustomEmoji.find_by(id: @parsed.custom_emoji_id)
             else
               CustomEmoji.local.find_by(shortcode: @parsed.shortcode)
             end
    invalid!(@parsed.custom_emoji_id ? 'emoji.custom_emoji_id' : 'emoji.shortcode', 'unavailable_emoji') unless record
    invalid!('emoji.scope', 'contradictory_scope') unless record.local?
    invalid!('emoji.shortcode', 'contradictory_field') if @parsed.shortcode && @parsed.shortcode != record.shortcode
    invalid!('emoji', 'disabled') if record.disabled?
    invalid!('emoji', 'unavailable_emoji') if @parsed.custom_emoji_id.nil? && !record.visible_in_picker?
    record
  end

  def generate_id
    used = @categories.flat_map { |category| [category.fetch('id'), *category.fetch('items').map { |item| item.fetch('id') }] }.to_set
    loop do
      candidate = "i#{SecureRandom.hex(8)}"
      return candidate if used.exclude?(candidate)
    end
  end

  def unchanged_result(item_id)
    result_for(@revision, @record&.categories || [], item_id, added: false)
  end

  def result_for(revision, categories, item_id, added:)
    document = PersonalEmojiSets::Document.new(
      revision: revision,
      categories: categories,
      picker_emoji_size: PersonalEmojiSets::PickerSize.current(@locked.id)
    )
    Result.new(document: document, added: added, category_id: @category_id, item_id: item_id)
  end

  def invalid!(path, code)
    raise EmojiReferences::Invalid.new(path, code)
  end
end
