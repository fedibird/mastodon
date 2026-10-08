# frozen_string_literal: true

require 'rails_helper'

def posting_style_attributes(group)
  {
    name: 'サークル告知',
    icon: '📣',
    purpose: 'サークル向けの告知',
    target_kind: 'group',
    target_account: group,
    defaults: { 'visibility' => 'private', 'language' => { 'mode' => 'auto' } },
    managed: {
      'hashtags' => [
        {
          'name' => 'fedibird',
          'normalized_name' => 'fedibird',
          'enforcement' => 'advisory',
          'rule_id' => UserPostingContext::ADVISORY_HASHTAG_RULE_ID,
        },
      ],
    },
  }
end

RSpec.describe Api::V1::Fedibird::UserPostingContextsController do
  render_views

  let(:owner) { user_with_role('Owner') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #index' do
    it 'returns only the signed-in owner’s enabled styles and does not discover groups' do
      expect(PostingContext::DiscoveryService).not_to receive(:new)
      group = Fabricate(:account, username: 'localsquad', actor_type: 'Group')
      style = owner.user_posting_contexts.create!(posting_style_attributes(group))
      owner.user_posting_contexts.create!(name: 'Hidden', enabled: false, defaults: {}, managed: { 'hashtags' => [] })
      other = user_with_role('Owner')
      other.user_posting_contexts.create!(name: 'Theirs', defaults: {}, managed: { 'hashtags' => [] })

      get :index

      expect(response).to have_http_status(200)
      expect(body_as_json.map { |item| item[:id] }).to eq [style.id.to_s]
      expect(body_as_json.first).to include(
        name: 'サークル告知',
        icon: '📣',
        purpose: 'サークル向けの告知',
        revision: style.lock_version,
        enabled: true
      )
      expect(body_as_json.first[:target]).to include(kind: 'group', account_id: group.id.to_s, label: 'localsquad')
      expect(body_as_json.first[:defaults]).to include(visibility: 'private')
      expect(body_as_json.first[:defaults][:language]).to eq(mode: 'auto')
      expect(body_as_json.first[:managed][:hashtags].first).to include(normalized_name: 'fedibird', enforcement: 'advisory')
    end

    it 'does not list styles for a non-administrator' do
      member = Fabricate(:user)
      member_token = Fabricate(:accessible_access_token, resource_owner_id: member.id, scopes: 'read')
      allow(controller).to receive(:doorkeeper_token) { member_token }

      get :index

      expect(response).to have_http_status(403)
    end
  end
end
