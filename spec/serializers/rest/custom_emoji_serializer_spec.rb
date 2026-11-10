# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::CustomEmojiSerializer do
  def emoji_json(emoji)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(emoji, serializer: described_class).to_json,
      symbolize_names: true
    )
  end

  def status_json(status)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        status,
        serializer: REST::StatusSerializer,
        scope: status.account.local? ? status.account.user : nil,
        scope_name: :current_user
      ).to_json,
      symbolize_names: true
    )
  end

  it 'exposes a local row id and a null domain' do
    emoji = Fabricate(:custom_emoji, shortcode: 'blob', domain: nil)
    json = emoji_json(emoji)

    expect(json[:id]).to eq(emoji.id.to_s)
    expect(json[:shortcode]).to eq('blob')
    expect(json[:domain]).to be_nil
  end

  it 'exposes a remote domain without using the cache id as that identity' do
    emoji = Fabricate(:custom_emoji, shortcode: 'blob', domain: 'remote.example')
    json = emoji_json(emoji)

    expect(json[:id]).to eq(emoji.id.to_s)
    expect(json[:domain]).to eq('remote.example')
    expect(json[:shortcode]).to eq('blob')
  end

  it 'carries the local id on a status emoji list' do
    emoji = Fabricate(:custom_emoji, shortcode: 'statusblob', domain: nil)
    status = Fabricate(:status, text: 'Hello :statusblob:')
    found = status_json(status)[:emojis].find { |item| item[:shortcode] == 'statusblob' }

    expect(found[:id]).to eq(emoji.id.to_s)
    expect(found[:domain]).to be_nil
  end

  it 'carries the author domain for a remote status emoji' do
    emoji = Fabricate(:custom_emoji, shortcode: 'remotebird', domain: 'emoji.example')
    account = Fabricate(:account, username: 'bird', domain: 'emoji.example')
    status = Fabricate(:status, account: account, text: 'Hello :remotebird:')
    found = status_json(status)[:emojis].find { |item| item[:shortcode] == 'remotebird' }

    expect(found[:id]).to eq(emoji.id.to_s)
    expect(found[:domain]).to eq('emoji.example')
    expect(found[:shortcode]).to eq('remotebird')
  end

  it 'omits a disabled emoji so the shortcode is not paired with an id' do
    Fabricate(:custom_emoji, shortcode: 'goneblob', domain: nil, disabled: true)
    status = Fabricate(:status, text: 'Hello :goneblob:')

    expect(status_json(status)[:emojis]).to eq([])
  end
end
