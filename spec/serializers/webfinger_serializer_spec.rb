# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebfingerSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(account, serializer: described_class).to_json,
      symbolize_names: true
    )
  end

  def rels
    json[:links].map { |link| link[:rel] }
  end

  describe 'local account' do
    let(:account) { Fabricate(:account, username: 'alice') }

    it 'returns profile, self, and subscribe relations' do
      expect(rels).to eq [
        'http://webfinger.net/rel/profile-page',
        'self',
        'http://ostatus.org/schema/1.0/subscribe',
      ]
      expect(json[:links][2][:template]).to end_with('?uri={uri}')
    end

    it 'adds an avatar relation when an avatar and content type are present' do
      account.update_columns(avatar_file_name: 'avatar.gif', avatar_content_type: 'image/gif')

      avatar = json[:links].find { |link| link[:rel] == 'http://webfinger.net/rel/avatar' }
      expect(avatar[:type]).to eq 'image/gif'
      expect(avatar[:href]).to be_present
    end

    it 'omits the avatar relation when the account has no avatar' do
      expect(rels).not_to include('http://webfinger.net/rel/avatar')
    end

    it 'omits the avatar relation when unauthenticated API access is disabled' do
      account.update_columns(avatar_file_name: 'avatar.gif', avatar_content_type: 'image/gif')
      previous = ENV['DISALLOW_UNAUTHENTICATED_API_ACCESS']
      ENV['DISALLOW_UNAUTHENTICATED_API_ACCESS'] = 'true'

      expect(rels).not_to include('http://webfinger.net/rel/avatar')
    ensure
      ENV['DISALLOW_UNAUTHENTICATED_API_ACCESS'] = previous
    end

    it 'omits the avatar relation in limited federation mode' do
      account.update_columns(avatar_file_name: 'avatar.gif', avatar_content_type: 'image/gif')
      previous = Rails.configuration.x.whitelist_mode
      Rails.configuration.x.whitelist_mode = true

      expect(rels).not_to include('http://webfinger.net/rel/avatar')
    ensure
      Rails.configuration.x.whitelist_mode = previous
    end
  end

  describe 'instance actor' do
    let(:account) { Account.representative }

    it 'returns profile, self, and subscribe relations' do
      expect(rels).to include(
        'http://webfinger.net/rel/profile-page',
        'self',
        'http://ostatus.org/schema/1.0/subscribe'
      )
      expect(json[:links].find { |link| link[:rel] == 'self' }[:href]).to include('/actor')
    end
  end
end