# frozen_string_literal: true

class PersonalEmojiSets::Stock
  include RoutingHelper

  def initialize(categories)
    @categories = categories
    ids = categories.flat_map { |category| category.fetch('items') }.filter_map { |item| item['custom_emoji_id'] }.uniq
    @custom_emojis = ids.empty? ? {} : CustomEmoji.local.where(id: ids).index_by { |emoji| emoji.id.to_s }
  end

  def as_json
    {
      categories: @categories.map do |category|
        {
          id: category.fetch('id'),
          name: category.fetch('name'),
          heading: heading(category),
          items: category.fetch('items').filter_map do |item|
            resolved = resolved_items.fetch(item.fetch('id'))
            resolved.except(:available).merge(key: item.fetch('id')) if resolved.fetch(:available)
          end,
        }
      end,
    }
  end

  def resolved_items
    @resolved_items ||= @categories.flat_map { |category| category.fetch('items') }.to_h do |item|
      [item.fetch('id'), item['kind'] == 'custom' ? custom_item(item) : unicode_item(item)]
    end
  end

  # Definition revisions do not change when an administrator changes an image
  # or disables an emoji. Include the referenced records in HTTP freshness.
  def fingerprint
    [PersonalEmojiSets::UnicodeCatalog.fingerprint, *@custom_emojis.values.sort_by(&:id).map(&:cache_key_with_version)]
  end

  private

  def heading(category)
    result = { text: category.fetch('name').grapheme_clusters.first || '?' }
    definition = category.fetch('heading')
    return result if definition['mode'] == 'initial'

    # Pick the reference before filtering unavailable entries, not the first
    # available/search-matching entry in the rendered list.
    item_id = definition['mode'] == 'emoji' ? definition['item_id'] : category.fetch('items').first&.fetch('id')
    resolved = resolved_items[item_id]
    result[:image] = resolved.fetch(:image) if resolved && resolved[:available]
    result
  end

  def unicode_item(item)
    native = item.fetch('native')
    emoji = PersonalEmojiSets::UnicodeCatalog.find(native)
    return unavailable(native, { kind: 'unicode', native: native }) unless emoji

    {
      available: true,
      label: emoji.fetch(:label),
      image: { src: full_asset_url("/emoji/#{emoji.fetch(:filename)}.svg"), alt: native, title: emoji.fetch(:label), width: 36, height: 36 },
      search: emoji.fetch(:search),
      selection: { id: emoji.fetch(:id), custom: false, native: native },
      reference: { kind: 'unicode', native: native },
    }
  end

  def custom_item(item)
    emoji = @custom_emojis[item.fetch('custom_emoji_id')]
    reference = custom_reference(item, emoji)
    return unavailable(":#{item.fetch('shortcode')}:", reference) unless emoji && !emoji.disabled? && emoji.image_file_name.present?

    label = emoji.alternate_name.presence || emoji.shortcode
    colons = ":#{emoji.shortcode}:"
    {
      available: true,
      label: label,
      image: {
        src: full_asset_url(emoji.image.url(:static), ext: '.png'),
        animatedSrc: full_asset_url(emoji.image.url),
        alt: colons,
        title: label,
        width: emoji.width,
        height: emoji.height,
      },
      search: [emoji.shortcode, emoji.alternate_name, emoji.reading, emoji.ruby, *emoji.aliases].compact_blank.uniq,
      selection: { id: emoji.shortcode, custom: true, native: colons, colons: colons },
      reference: reference,
    }
  end

  def custom_reference(item, emoji)
    {
      kind: 'custom',
      scope: 'local',
      custom_emoji_id: item.fetch('custom_emoji_id'),
      shortcode: emoji&.shortcode || item.fetch('shortcode'),
    }
  end

  def unavailable(label, reference = nil)
    payload = { available: false, label: label, reason: 'unavailable' }
    payload[:reference] = reference if reference
    payload
  end
end
