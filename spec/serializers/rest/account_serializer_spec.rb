# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::AccountSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        account,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  describe 'local account' do
    let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
    let(:account) { user.account }

    it 'returns the ActivityPub actor URI' do
      expect(json[:uri]).to eq(ActivityPub::TagManager.instance.uri_for(account))
      expect(json[:uri]).not_to eq(json[:url])
    end

    it 'omits memorial and limited for a normal account' do
      expect(json).not_to have_key(:memorial)
      expect(json).not_to have_key(:limited)
    end

    it 'includes noindex false by default' do
      expect(json).to include(noindex: false)
    end

    it 'includes noindex true when enabled' do
      user.settings['noindex'] = true
      expect(json[:noindex]).to be true
    end
  end

  describe 'remote account' do
    let(:account) { Fabricate(:account, username: 'alice', domain: 'remote.example', uri: 'https://remote.example/users/alice', url: 'https://remote.example/@alice') }

    it 'returns the stored ActivityPub URI' do
      expect(json[:uri]).to eq(account.uri)
      expect(json[:uri]).to eq('https://remote.example/users/alice')
      expect(json).not_to have_key(:noindex)
    end
  end

  describe 'memorial account' do
    let(:account) { Fabricate(:account, username: 'alice') }

    before { account.memorialize! }

    it 'includes memorial=true' do
      expect(json[:memorial]).to be true
    end
  end

  describe 'limited account' do
    let(:account) { Fabricate(:account, username: 'alice') }

    before { account.silence! }

    it 'includes limited=true' do
      expect(json[:limited]).to be true
      expect(json).not_to have_key(:silenced)
    end
  end
end
