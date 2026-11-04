# frozen_string_literal: true

require 'rails_helper'

# Opt-in. This environment does not ship the analysis plugins GroupDirectoryIndex
# needs, and ES_ENABLED is false in test. A skip here is not a passing search.
RSpec.describe 'Group directory live Elasticsearch', :elasticsearch do
  def reachable?
    return false unless ENV['GROUP_DIRECTORY_ES_LIVE'] == 'true'
    return false unless ENV['ES_ENABLED'] == 'true'

    Chewy.client.cluster.health
    true
  rescue StandardError
    false
  end

  it 'indexes one group and reads it back through the API' do
    skip 'Live Elasticsearch was not requested or is not reachable. This skip is not a pass.' unless reachable?

    created = false
    swapped = false
    previous_search = ENV['GROUP_DIRECTORY_ES_SEARCH']
    previous_index = ENV['GROUP_DIRECTORY_INDEX']
    begin
      GroupDirectoryIndex.purge if GroupDirectoryIndex.exists?
      GroupDirectoryIndex.create!
      created = true
    rescue StandardError => e
      skip "GroupDirectoryIndex could not be created (#{e.class}: #{e.message.to_s.truncate(120)}). This skip is not a pass."
    end

    user = Fabricate(:user, confirmed_at: 10.days.ago, approved: true)
    token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
    account = Fabricate(:account, username: 'live_group', actor_type: 'Group', discoverable: true, display_name: 'Live Group', user: user)
    account.create_account_stat!
    GroupDirectoryIndex.import!([account.id])
    GroupDirectoryIndex.client.indices.refresh(index: GroupDirectoryIndex.index_name)

    ENV['GROUP_DIRECTORY_ES_SEARCH'] = 'true'
    ENV['GROUP_DIRECTORY_INDEX'] = 'true'
    swapped = true
    allow(Chewy).to receive(:enabled?).and_return(true)

    get '/api/v1/group_directory', headers: { 'Authorization' => "Bearer #{token.token}" }, params: { q: 'Live' }

    expect(response).to have_http_status(200)
    expect(body_as_json.pluck(:id)).to eq([account.id.to_s])
  ensure
    if swapped
      previous_search.nil? ? ENV.delete('GROUP_DIRECTORY_ES_SEARCH') : ENV['GROUP_DIRECTORY_ES_SEARCH'] = previous_search
      previous_index.nil? ? ENV.delete('GROUP_DIRECTORY_INDEX') : ENV['GROUP_DIRECTORY_INDEX'] = previous_index
    end
    GroupDirectoryIndex.purge if created
  end
end
