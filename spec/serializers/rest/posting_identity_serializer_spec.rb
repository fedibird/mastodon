# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::PostingIdentitySerializer do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice', display_name: 'Hi :blob:')) }
  let!(:emoji) { Fabricate(:custom_emoji, shortcode: 'blob', domain: nil) }

  it 'includes custom emoji records needed to render the display name' do
    json = JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        PostingIdentity::Local.build(user),
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )

    emoji_json = json[:account][:emojis].find { |item| item[:shortcode] == 'blob' }

    expect(json[:account][:display_name]).to eq('Hi :blob:')
    expect(emoji_json).to be_present
    expect(emoji_json[:url]).to start_with('http')
    expect(emoji_json[:static_url]).to start_with('http')
    expect(emoji.shortcode).to eq('blob')
  end
end
