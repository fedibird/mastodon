# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonalEmojiSets::Stock do
  def definition(items:, name: 'Favorites', heading: { 'mode' => 'first' })
    PersonalEmojiSets::Definition.new([{ 'id' => 'category', 'name' => name, 'heading' => heading, 'items' => items }]).validate!
  end

  def unicode_item(id, native)
    { 'id' => id, 'kind' => 'unicode', 'native' => native }
  end

  it 'uses the whole first grapheme, and initial mode never uses an image' do
    categories = definition(items: [unicode_item('thumb', '👍🏽')], name: '👩‍👩‍👦 家族', heading: { 'mode' => 'initial' })
    heading = described_class.new(categories).as_json.fetch(:categories).first.fetch(:heading)

    expect(heading).to eq(text: '👩‍👩‍👦')
    categories.first['name'] = "e\u0301moji"
    expect(described_class.new(categories).as_json[:categories].first[:heading]).to eq(text: "e\u0301")
  end

  it 'supplies individual Unicode images and does not change the selected native value' do
    categories = definition(items: [unicode_item('thumb', '👍🏽'), unicode_item('doctor', '👨🏿‍⚕️')])
    stock = described_class.new(categories)
    items = stock.as_json.fetch(:categories).first.fetch(:items)

    expect(items.first.fetch(:image).fetch(:src)).to end_with '/emoji/1f44d-1f3fd.svg'
    expect(items.first.fetch(:selection)).to eq(id: '+1', custom: false, native: '👍🏽')
    expect(items.last.fetch(:selection).fetch(:native)).to eq '👨🏿‍⚕️'
    expect(items.first.fetch(:search)).to include('いいね')
  end

  it 'keeps an explicit representative attached to its placement, not its array index' do
    categories = definition(items: [unicode_item('light', '👍🏻'), unicode_item('dark', '👍🏿')], heading: { 'mode' => 'emoji', 'item_id' => 'dark' })
    categories.first.fetch('items').reverse!
    stock = described_class.new(categories).as_json

    expect(stock[:categories].first[:heading][:image][:alt]).to eq '👍🏿'
  end

  context 'with custom emoji' do
    let!(:emoji) { Fabricate(:custom_emoji, shortcode: 'wide_emoji') }
    let(:items) { [{ 'id' => 'wide', 'kind' => 'custom', 'shortcode' => emoji.shortcode }, unicode_item('thumb', '👍🏽')] }

    it 'does not promote a different emoji when the saved first representative becomes unavailable' do
      categories = definition(items: items, name: '横長')
      emoji.update!(disabled: true)
      stock = described_class.new(categories)

      expect(stock.as_json[:categories].first[:heading]).to eq(text: '横')
      expect(stock.as_json[:categories].first[:items].map { |item| item[:key] }).to eq ['thumb']
      expect(stock.resolved_items.fetch('wide')).to eq(available: false, label: ':wide_emoji:', reason: 'unavailable')
      expect(categories.first.fetch('items').first.fetch('custom_emoji_id')).to eq emoji.id.to_s
    end

    it 'does not resolve a deleted reference to a replacement with the same shortcode' do
      categories = definition(items: items, heading: { 'mode' => 'emoji', 'item_id' => 'wide' })
      emoji.destroy!
      Fabricate(:custom_emoji, shortcode: 'wide_emoji')
      stock = described_class.new(categories)

      expect(stock.resolved_items.fetch('wide')[:available]).to be false
      expect(stock.as_json[:categories].first[:heading]).to eq(text: 'F')
    end

    it 'uses current metadata, dimensions and callbacks while retaining the saved identity' do
      categories = definition(items: items)
      emoji.update_columns(shortcode: 'renamed_emoji', alternate_name: '横長の絵文字', reading: 'よこなが', ruby: 'ヨコナガ', aliases: ['wide', 'long'], width: 320, height: 32, visible_in_picker: false)
      expect_any_instance_of(Paperclip::Attachment).not_to receive(:exists?)
      resolved = described_class.new(categories).resolved_items.fetch('wide')

      expect(resolved[:available]).to be true
      expect(resolved[:label]).to eq '横長の絵文字'
      expect(resolved[:image]).to include(width: 320, height: 32, alt: ':renamed_emoji:')
      expect(resolved[:search]).to include('よこなが', 'ヨコナガ', 'wide', 'long')
      expect(resolved[:selection]).to eq(id: 'renamed_emoji', custom: true, native: ':renamed_emoji:', colons: ':renamed_emoji:')
    end

    it 'loads all referenced custom emoji with one database query regardless of placements' do
      categories = definition(items: items)
      categories << categories.first.deep_dup.merge('id' => 'second', 'items' => [categories.first.fetch('items').first.merge('id' => 'wide-copy')])
      queries = []
      listener = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].match?(/SELECT .*FROM "custom_emojis"/m) }

      ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
        stock = described_class.new(categories)
        stock.as_json
        stock.resolved_items
        stock.fingerprint
      end

      expect(queries.size).to eq 1
      expect(queries.first).to include('"custom_emojis"."id"')
    end

    it 'changes stock freshness when a referenced record changes without changing the definition revision' do
      categories = definition(items: items)
      first = PersonalEmojiSets::Document.new(revision: 5, categories: categories, picker_emoji_size: 22)
      etag = first.etag(123)
      emoji.update_columns(updated_at: Time.current + 1.minute)
      second = PersonalEmojiSets::Document.new(revision: 5, categories: categories, picker_emoji_size: 22)

      expect(second.revision).to eq first.revision
      expect(second.etag(123)).not_to eq etag
      expect(second.etag(456)).not_to eq second.etag(123)
    end
  end
end
