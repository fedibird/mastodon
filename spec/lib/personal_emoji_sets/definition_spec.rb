# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonalEmojiSets::Definition do
  def unicode_item(id = 'thumb', native = '👍🏽')
    { 'id' => id, 'kind' => 'unicode', 'native' => native }
  end

  def category(items = [], **options)
    { 'id' => 'favorites', 'name' => 'Favorites', 'items' => items }.merge(options.stringify_keys)
  end

  def validate(categories, previous: [])
    described_class.new(categories, previous: previous).validate!
  end

  def invalid_code(categories)
    validate(categories)
    nil
  rescue PersonalEmojiSets::Invalid => error
    error.errors.first[:code]
  end

  it 'allows an empty set and empty categories, and defaults a missing heading to first' do
    expect(validate([])).to eq []
    expect(validate([category]).first).to include('items' => [], 'heading' => { 'mode' => 'first' })
  end

  it 'preserves finished Unicode strings and canonicalizes client-supplied identifiers' do
    strings = ['👍🏽', '👍🏻', '👨🏿‍⚕️', '🕵🏽‍♀️', '1️⃣', '👩‍❤️‍💋‍👩']
    items = strings.each_with_index.map { |native, index| unicode_item("emoji-#{index}", native).merge('emoji_id' => 'incorrect-client-id') }
    result = validate([category(items)]).first.fetch('items')

    expect(result.pluck('native')).to eq strings
    expect(result.first.fetch('emoji_id')).to eq '+1'
    expect(result[3].fetch('emoji_id')).to eq 'female-detective'
    expect(result.flat_map(&:keys)).not_to include('label')
  end

  it 'counts category names by grapheme and trims Unicode whitespace' do
    name = "e\u0301" * 60
    expect(validate([category(name: "　#{name}　")]).first.fetch('name')).to eq name
    expect(invalid_code([category(name: "e\u0301" * 61)])).to eq 'invalid_name'
    expect(invalid_code([category(name: '　 ')])).to eq 'invalid_name'
  end

  it 'keeps the representative placement identity after reordering' do
    items = [unicode_item('light', '👍🏻'), unicode_item('dark', '👍🏿')]
    saved = validate([category(items, heading: { 'mode' => 'emoji', 'item_id' => 'dark' })])
    saved.first['items'].reverse!

    expect(validate(saved).first.fetch('heading')).to eq('mode' => 'emoji', 'item_id' => 'dark')
    expect(invalid_code([category(items, heading: { 'mode' => 'emoji', 'item_id' => 'outside' })])).to eq 'invalid_representative'
  end

  it 'permits the same emoji across categories and distinct skin variants in one category' do
    result = validate([
      category([unicode_item('a'), unicode_item('b', '👍🏻')]),
      category([unicode_item('c')], id: 'second'),
    ])

    expect(result.map { |entry| entry.fetch('items').size }).to eq [2, 1]
    expect(invalid_code([category([unicode_item('a'), unicode_item('b')])])).to eq 'duplicate_emoji'
  end

  it 'rejects duplicate category and placement identities, including across categories' do
    expect(invalid_code([category, category])).to eq 'duplicate_id'
    expect(invalid_code([category([unicode_item]), category([unicode_item], id: 'second')])).to eq 'duplicate_id'
    expect(invalid_code([category(id: 'id with spaces')])).to eq 'invalid_id'
  end

  it 'bounds categories, per-category placements, and the total number of placements' do
    expect(invalid_code(Array.new(51) { |index| category(id: "category-#{index}") })).to eq 'too_many_categories'
    expect(invalid_code([category(Array.new(201) { |index| unicode_item("emoji-#{index}") })])).to eq 'too_many_items'
    categories = Array.new(6) do |index|
      category(Array.new(200) { |position| unicode_item("#{index}-#{position}") }, id: "category-#{index}")
    end
    expect(invalid_code(categories)).to eq 'too_many_items'
  end

  it 'rejects arbitrary text, image URLs, invalid types, and out-of-range database ids' do
    expect(invalid_code([category([unicode_item('a', '<script>')])])).to eq 'invalid_unicode'
    expect(invalid_code([category([unicode_item.merge('image' => { 'src' => 'https://example.org/untrusted.svg' })])])).to eq 'unknown_field'
    expect(invalid_code([category([unicode_item.merge('label' => [])])])).to eq 'invalid_type'
    expect(invalid_code([category([{ 'id' => 'a', 'kind' => 'custom', 'custom_emoji_id' => '9223372036854775808' }])])).to eq 'invalid_id'
    expect(invalid_code({})).to eq 'invalid_type'
  end

  context 'with custom emoji references' do
    let!(:emoji) { Fabricate(:custom_emoji, shortcode: 'wide_emoji') }

    it 'resolves a new shortcode to its current database identity and ignores client aliases' do
      result = validate([category([{ 'id' => 'wide', 'kind' => 'custom', 'shortcode' => emoji.shortcode }])])
      item = result.first.fetch('items').first
      expect(item).to eq('id' => 'wide', 'kind' => 'custom', 'custom_emoji_id' => emoji.id.to_s, 'shortcode' => 'wide_emoji')
    end

    it 'preserves disabled or removed references without binding to a replacement shortcode' do
      previous = validate([category([{ 'id' => 'wide', 'kind' => 'custom', 'shortcode' => emoji.shortcode }])])
      emoji.update!(disabled: true)
      expect(validate(previous, previous: previous)).to eq previous

      old_id = emoji.id.to_s
      emoji.destroy!
      replacement = Fabricate(:custom_emoji, shortcode: 'wide_emoji')
      result = validate(previous, previous: previous)
      expect(result.first.fetch('items').first.fetch('custom_emoji_id')).to eq old_id
      expect(result.first.fetch('items').first.fetch('custom_emoji_id')).not_to eq replacement.id.to_s

      copy = previous.deep_dup
      copy << category([previous.first.fetch('items').first.merge('id' => 'wide-copy')], id: 'copy')
      expect(validate(copy, previous: previous).last.fetch('items').first.fetch('custom_emoji_id')).to eq old_id
    end

    it 'accepts an explicit id for an enabled unlisted emoji and keeps shortcode-only adds listed' do
      emoji.update!(visible_in_picker: false)
      explicit = { 'id' => 'wide', 'kind' => 'custom', 'custom_emoji_id' => emoji.id.to_s }
      item = validate([category([explicit])]).first.fetch('items').first

      expect(item.fetch('custom_emoji_id')).to eq emoji.id.to_s
      expect(item.fetch('shortcode')).to eq 'wide_emoji'
      expect(invalid_code([category([{ 'id' => 'wide', 'kind' => 'custom', 'shortcode' => emoji.shortcode }])])).to eq 'unavailable_emoji'
    end

    it 'keeps a hidden emoji on a later save and still refuses a new disabled or remote id' do
      previous = validate([category([{ 'id' => 'wide', 'kind' => 'custom', 'shortcode' => emoji.shortcode }])])
      emoji.update!(visible_in_picker: false)
      expect(validate(previous)).to eq previous

      emoji.update!(disabled: true, visible_in_picker: true)
      expect(invalid_code([category([{ 'id' => 'fresh', 'kind' => 'custom', 'custom_emoji_id' => emoji.id.to_s }])])).to eq 'unavailable_emoji'
      expect(validate(previous, previous: previous).first.fetch('items').first.fetch('custom_emoji_id')).to eq emoji.id.to_s

      remote = Fabricate(:custom_emoji, shortcode: 'remote_emoji', domain: 'remote.example')
      expect(invalid_code([category([{ 'id' => 'remote', 'kind' => 'custom', 'custom_emoji_id' => remote.id.to_s }])])).to eq 'unavailable_emoji'
    end

    it 'deduplicates custom references by database identity within a category' do
      items = [
        { 'id' => 'a', 'kind' => 'custom', 'shortcode' => emoji.shortcode },
        { 'id' => 'b', 'kind' => 'custom', 'custom_emoji_id' => emoji.id.to_s },
      ]
      expect(invalid_code([category(items)])).to eq 'duplicate_emoji'
    end
  end
end
