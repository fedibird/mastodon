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

    it 'omits memorial, limited, and moved for a normal account' do
      expect(json).not_to have_key(:memorial)
      expect(json).not_to have_key(:limited)
      expect(json).not_to have_key(:moved)
    end

    it 'includes noindex false by default' do
      expect(json).to include(noindex: false)
    end

    it 'includes noindex true when enabled' do
      user.settings['noindex'] = true
      expect(json[:noindex]).to be true
    end

    it 'returns a highlighted custom role and hides one that is not highlighted' do
      shown = UserRole.create!(name: 'Visible helper', permissions_as_keys: %w(manage_reports), highlighted: true, color: '#336699')
      hidden = UserRole.create!(name: 'Quiet helper', permissions_as_keys: %w(manage_reports), highlighted: false)
      user.update_columns(role_id: shown.id)

      expect(json[:roles]).to eq [{ id: shown.id.to_s, name: 'Visible helper', color: '#336699' }]

      user.update_columns(role_id: hidden.id)
      hidden_json = JSON.parse(ActiveModelSerializers::SerializableResource.new(account.reload, serializer: described_class).to_json, symbolize_names: true)
      expect(hidden_json[:roles]).to eq []
    end

    it 'uses the same highlighted rule for Owner, Admin, and Moderator' do
      load Rails.root.join('db', 'seeds', '03_roles.rb')

      %w(Owner Admin Moderator).each do |name|
        role = UserRole.find_by!(name: name)
        role.update!(highlighted: false)
        user.update_columns(role_id: role.id)
        hidden_json = JSON.parse(ActiveModelSerializers::SerializableResource.new(account.reload, serializer: described_class).to_json, symbolize_names: true)
        expect(hidden_json[:roles]).to eq []

        role.update!(highlighted: true, color: '#abcdef')
        shown_json = JSON.parse(ActiveModelSerializers::SerializableResource.new(account.reload, serializer: described_class).to_json, symbolize_names: true)
        expect(shown_json[:roles]).to eq [{ id: role.id.to_s, name: name, color: '#abcdef' }]
      end
    end

    it 'returns an empty roles array for a suspended local account' do
      role = UserRole.create!(name: 'Visible helper', permissions_as_keys: %w(manage_reports), highlighted: true)
      user.update_columns(role_id: role.id)
      account.suspend!

      expect(json[:roles]).to eq []
    end
  end

  describe 'remote account' do
    let(:account) { Fabricate(:account, username: 'alice', domain: 'remote.example', uri: 'https://remote.example/users/alice', url: 'https://remote.example/@alice') }

    it 'returns the stored ActivityPub URI' do
      expect(json[:uri]).to eq(account.uri)
      expect(json[:uri]).to eq('https://remote.example/users/alice')
      expect(json).not_to have_key(:noindex)
      expect(json).not_to have_key(:roles)
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

RSpec.describe REST::AccountSerializer, 'moved accounts' do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(account, serializer: described_class).to_json,
      symbolize_names: true
    )
  end

  let(:account) { Fabricate(:account, username: 'alice') }

  it 'includes the direct moved-to account' do
    target = Fabricate(:account, username: 'bob')
    account.update!(moved_to_account: target)
    expect(json.dig(:moved, :id)).to eq(target.id.to_s)
  end

  it 'omits nested moved when the target has itself moved' do
    middle = Fabricate(:account, username: 'bob')
    final = Fabricate(:account, username: 'carol')
    middle.update!(moved_to_account: final)
    account.update!(moved_to_account: middle)
    expect(json.dig(:moved, :id)).to eq(middle.id.to_s)
    expect(json[:moved]).not_to have_key(:moved)
  end
end
