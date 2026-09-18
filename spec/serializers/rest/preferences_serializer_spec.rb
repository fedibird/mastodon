# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::PreferencesSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        account,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:user) { Fabricate(:user) }
  let(:account) { user.account }

  it 'returns false by default' do
    expect(json).to include('reading:autoplay:gifs': false)
  end

  it 'returns true when all autoplay settings are enabled' do
    enable_autoplay!

    expect(json[:'reading:autoplay:gifs']).to be true
  end

  it 'returns false when any autoplay setting is disabled' do
    enable_autoplay!
    user.settings['auto_play_media'] = false

    expect(json[:'reading:autoplay:gifs']).to be false
  end

  def enable_autoplay!
    user.settings['auto_play_avatar'] = true
    user.settings['auto_play_emoji'] = true
    user.settings['auto_play_header'] = true
    user.settings['auto_play_media'] = true
  end
end
