# frozen_string_literal: true

class PersonalEmojiSets::Definition
  MAX_CATEGORIES = 50
  MAX_CATEGORY_ITEMS = 200
  MAX_ITEMS = 1_000
  MAX_NAME_GRAPHEMES = 60
  MAX_BODY_BYTES = 512.kilobytes
  ID_PATTERN = /\A[a-zA-Z0-9_-]{1,64}\z/.freeze
  DATABASE_ID_PATTERN = /\A[1-9][0-9]{0,18}\z/.freeze
  MAX_DATABASE_ID = (2**63) - 1

  def initialize(categories, previous: [])
    @categories = categories
    @category_ids = Set.new
    @item_ids = Set.new
    @previous_items = previous.flat_map { |category| category.fetch('items') }
    @previous_custom = @previous_items.select { |item| item['kind'] == 'custom' }.index_by { |item| item['custom_emoji_id'] }
    @previous_unicode = @previous_items.select { |item| item['kind'] == 'unicode' }.index_by { |item| item['native'] }
  end

  def validate!
    invalid!('categories', 'invalid_type') unless @categories.is_a?(Array)
    invalid!('categories', 'too_many_categories') if @categories.size > MAX_CATEGORIES

    shaped = @categories.each_with_index.map { |category, index| category_shape(category, "categories.#{index}") }
    load_custom_emojis(shaped)

    shaped.each_with_index.map do |category, index|
      path = "categories.#{index}"
      items = category.fetch('items').each_with_index.map { |item, item_index| resolve_item(item, "#{path}.items.#{item_index}") }
      identities = items.map { |item| item['kind'] == 'unicode' ? ['unicode', item['native']] : ['custom', item['custom_emoji_id']] }
      invalid!("#{path}.items", 'duplicate_emoji') unless identities.uniq.size == identities.size

      category.merge('items' => items)
    end
  end

  private

  def category_shape(category, path)
    fields!(category, %w(id name heading items), path)
    id!(category['id'], @category_ids, "#{path}.id")
    name = category['name']
    invalid!("#{path}.name", 'invalid_name') unless name.is_a?(String) && name.bytesize <= 1_024
    name = name.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
    invalid!("#{path}.name", 'invalid_name') unless name.present? && name.grapheme_clusters.size <= MAX_NAME_GRAPHEMES
    items = category['items']
    invalid!("#{path}.items", 'invalid_type') unless items.is_a?(Array)
    invalid!("#{path}.items", 'too_many_items') if items.size > MAX_CATEGORY_ITEMS || @item_ids.size + items.size > MAX_ITEMS
    items = items.each_with_index.map { |item, index| item_shape(item, "#{path}.items.#{index}") }

    {
      'id' => category['id'],
      'name' => name,
      'heading' => heading_shape(category['heading'], items, "#{path}.heading"),
      'items' => items,
    }
  end

  def heading_shape(heading, items, path)
    return { 'mode' => 'first' } if heading.nil?

    fields!(heading, %w(mode item_id), path)
    mode = heading['mode'] || 'first'
    invalid!("#{path}.mode", 'invalid_mode') unless %w(first initial emoji).include?(mode)
    return { 'mode' => mode } unless mode == 'emoji'

    item_id = heading['item_id']
    invalid!("#{path}.item_id", 'invalid_representative') unless item_id.is_a?(String) && items.any? { |item| item['id'] == item_id }
    { 'mode' => mode, 'item_id' => item_id }
  end

  def item_shape(item, path)
    fields!(item, %w(id kind native emoji_id label custom_emoji_id shortcode), path)
    id!(item['id'], @item_ids, "#{path}.id")
    invalid!("#{path}.kind", 'invalid_kind') unless %w(unicode custom).include?(item['kind'])

    if item['kind'] == 'unicode'
      fields!(item, %w(id kind native emoji_id label), path)
      invalid!("#{path}.native", 'invalid_unicode') unless item['native'].is_a?(String) && item['native'].bytesize.between?(1, 128)
      %w(emoji_id label).each do |key|
        invalid!("#{path}.#{key}", 'invalid_type') if item.key?(key) && (!item[key].is_a?(String) || item[key].bytesize > 512)
      end
    else
      fields!(item, %w(id kind custom_emoji_id shortcode), path)
      if item.key?('custom_emoji_id')
        value = item['custom_emoji_id']
        invalid!("#{path}.custom_emoji_id", 'invalid_id') unless value.is_a?(String) && DATABASE_ID_PATTERN.match?(value) && value.to_i <= MAX_DATABASE_ID
      end
      shortcode = item['shortcode']
      valid_shortcode = shortcode.is_a?(String) && shortcode.bytesize <= 100 && /\A#{CustomEmoji::SHORTCODE_RE_FRAGMENT}\z/.match?(shortcode)
      invalid!("#{path}.shortcode", 'invalid_shortcode') if (item.key?('shortcode') || !item.key?('custom_emoji_id')) && !valid_shortcode
    end

    item
  end

  def load_custom_emojis(categories)
    items = categories.flat_map { |category| category.fetch('items') }.select { |item| item['kind'] == 'custom' }
    ids = items.filter_map { |item| item['custom_emoji_id'] }.uniq
    shortcodes = items.reject { |item| item.key?('custom_emoji_id') }.map { |item| item['shortcode'] }.uniq
    records = if ids.empty? && shortcodes.empty?
                []
              else
                CustomEmoji.local.where(id: ids).or(CustomEmoji.local.where(shortcode: shortcodes)).to_a
              end
    @custom_by_id = records.index_by { |emoji| emoji.id.to_s }
    @custom_by_shortcode = records.index_by(&:shortcode)
  end

  def resolve_item(item, path)
    return resolve_unicode(item, path) if item['kind'] == 'unicode'

    explicit_id = item['custom_emoji_id']
    record = explicit_id ? @custom_by_id[explicit_id] : @custom_by_shortcode[item['shortcode']]
    previous = explicit_id && @previous_custom[explicit_id]
    invalid!(path, 'unavailable_emoji') unless kept_custom?(record, previous, explicit_id)

    {
      'id' => item['id'],
      'kind' => 'custom',
      'custom_emoji_id' => record ? record.id.to_s : explicit_id,
      'shortcode' => record ? record.shortcode : previous.fetch('shortcode'),
    }
  end

  # An explicit database id may name an enabled local emoji that is hidden
  # from the standard picker. A shortcode, and any remote or disabled row,
  # still cannot be newly added. Previously saved rows stay pinned by id.
  def kept_custom?(record, previous, explicit_id)
    return true if previous
    return false unless record&.local? && !record.disabled?

    explicit_id.present? || record.visible_in_picker?
  end

  def resolve_unicode(item, path)
    emoji = PersonalEmojiSets::UnicodeCatalog.find(item['native'])
    previous = @previous_unicode[item['native']]
    invalid!("#{path}.native", 'invalid_unicode') unless emoji || previous

    {
      'id' => item['id'],
      'kind' => 'unicode',
      'native' => item['native'],
      'emoji_id' => emoji ? emoji.fetch(:id) : previous.fetch('emoji_id'),
    }
  end

  def fields!(value, allowed, path)
    invalid!(path, 'invalid_type') unless value.is_a?(Hash)
    invalid!(path, 'unknown_field') unless (value.keys - allowed).empty?
  end

  def id!(value, seen, path)
    invalid!(path, 'invalid_id') unless value.is_a?(String) && ID_PATTERN.match?(value)
    invalid!(path, 'duplicate_id') unless seen.add?(value)
  end

  def invalid!(path, code)
    raise PersonalEmojiSets::Invalid.new(path, code)
  end
end
