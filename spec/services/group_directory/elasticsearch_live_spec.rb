# frozen_string_literal: true

require 'rails_helper'

# Opt-in. This environment does not ship the analysis plugins GroupDirectoryIndex
# needs, and ES_ENABLED is false in test. A skip here is not a passing search.
# This example never deletes the configured GroupDirectoryIndex. It creates
# only a temporary name and deletes that name.
RSpec.describe 'Group directory live Elasticsearch', :elasticsearch do
  def reachable?
    return false unless ENV['GROUP_DIRECTORY_ES_LIVE'] == 'true'
    return false unless ENV['ES_ENABLED'] == 'true'

    Chewy.client.cluster.health
    true
  rescue StandardError
    false
  end

  it 'indexes one group into a temporary index and reads it back' do
    skip 'Live Elasticsearch was not requested or is not reachable. This skip is not a pass.' unless reachable?

    real_name = GroupDirectoryIndex.index_name
    if Chewy.client.indices.exists?(index: real_name)
      skip 'An existing GroupDirectoryIndex is present. Refusing to touch it. This skip is not a pass.'
    end

    temporary = nil
    swapped = false
    previous_search = ENV['GROUP_DIRECTORY_ES_SEARCH']
    previous_index = ENV['GROUP_DIRECTORY_INDEX']
    begin
      temporary = GroupDirectory::LiveIndex.temporary_name(real_name)
      allow(GroupDirectoryIndex).to receive(:index_name).and_return(temporary)
      GroupDirectoryIndex.create!

      user = Fabricate(:user, confirmed_at: 10.days.ago, approved: true)
      token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
      account = Fabricate(:account, username: 'live_group', actor_type: 'Group', discoverable: true, display_name: 'Live Group', user: user)
      account.create_account_stat!
      GroupDirectoryIndex.import!([account.id])
      Chewy.client.indices.refresh(index: temporary)
      GroupDirectory::Indexing.mark_backfill_complete!

      ENV['GROUP_DIRECTORY_ES_SEARCH'] = 'true'
      ENV['GROUP_DIRECTORY_INDEX'] = 'true'
      swapped = true
      allow(Chewy).to receive(:enabled?).and_return(true)

      get '/api/v1/group_directory', headers: { 'Authorization' => "Bearer #{token.token}" }, params: { q: 'Live' }

      expect(response).to have_http_status(200)
      expect(body_as_json.pluck(:id)).to eq([account.id.to_s])
      expect(Chewy.client.indices.exists?(index: real_name)).to be false
    ensure
      if swapped
        previous_search.nil? ? ENV.delete('GROUP_DIRECTORY_ES_SEARCH') : ENV['GROUP_DIRECTORY_ES_SEARCH'] = previous_search
        previous_index.nil? ? ENV.delete('GROUP_DIRECTORY_INDEX') : ENV['GROUP_DIRECTORY_INDEX'] = previous_index
      end
      GroupDirectory::Indexing.clear_backfill_complete! if temporary
      GroupDirectory::LiveIndex.delete_temporary!(Chewy.client, temporary, real_name) if temporary
    end
  end
end
