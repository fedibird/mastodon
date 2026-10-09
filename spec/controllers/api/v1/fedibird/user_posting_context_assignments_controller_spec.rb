# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::UserPostingContextAssignmentsController do
  render_views

  let(:owner) { user_with_role('Owner') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read write') }
  let(:group) { Fabricate(:account, username: 'localsquad', actor_type: 'Group') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def style_for(user, **attributes)
    user.user_posting_contexts.create!({ name: 'Notes' }.merge(attributes))
  end

  describe 'GET #show' do
    it 'returns unset when this user has no row for the place' do
      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(status: 'unset', style_id: nil, revision: nil)
      expect(body_as_json[:surface]).to include(kind: 'group', key: group.id.to_s)
    end

    it 'does not return another user’s assignment' do
      other = user_with_role('Owner')
      style = style_for(other, target_kind: 'group', target_account: group)
      UserPostingContextAssignment.assign!(user: other, surface_kind: 'group', surface_key: group.id.to_s, style: style)

      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq('unset')
      expect(body_as_json[:style_id]).to be_nil
    end

    it 'returns none, style, and unavailable without substituting another style' do
      none = UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: group.id.to_s, style: nil)
      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(body_as_json).to include(status: 'none', style_id: nil, revision: none.lock_version)

      style = style_for(owner, name: 'Chosen', target_kind: 'group', target_account: group)
      style_for(owner, name: 'Other', target_kind: 'group', target_account: group)
      chosen = UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: group.id.to_s, style: style)
      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(body_as_json).to include(status: 'style', style_id: style.id.to_s, revision: chosen.lock_version)

      style.update!(enabled: false)
      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(body_as_json).to include(status: 'unavailable', style_id: style.id.to_s)
      expect(body_as_json[:style_id]).not_to eq(owner.user_posting_contexts.find_by(name: 'Other').id.to_s)
    end

    it 'rejects a non-administrator, a missing token, and a write-only token' do
      member = Fabricate(:user)
      member_token = Fabricate(:accessible_access_token, resource_owner_id: member.id, scopes: 'read')
      allow(controller).to receive(:doorkeeper_token) { member_token }
      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }
      expect(response).to have_http_status(403)

      allow(controller).to receive(:doorkeeper_token) { nil }
      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }
      expect(response).to have_http_status(401)

      write_token = Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'write')
      allow(controller).to receive(:doorkeeper_token) { write_token }
      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }
      expect(response).to have_http_status(403)
    end

    it 'accepts the read:accounts scope' do
      scoped = Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read:accounts')
      allow(controller).to receive(:doorkeeper_token) { scoped }

      get :show, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq('unset')
    end
  end

  describe 'PUT #update' do
    it 'saves a style, an explicit none, and a repeated value without a second row' do
      style = style_for(owner, target_kind: 'group', target_account: group)

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: style.id }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(status: 'style', style_id: style.id.to_s)
      expect(owner.user_posting_context_assignments.count).to eq(1)
      revision = body_as_json[:revision]

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: style.id }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:revision]).to eq(revision)
      expect(owner.user_posting_context_assignments.count).to eq(1)

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: nil }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(status: 'none', style_id: nil)
      expect(body_as_json[:revision]).to eq(revision + 1)
      expect(owner.user_posting_context_assignments.count).to eq(1)
    end

    it 'normalizes a hashtag and keeps a common style on a list' do
      tagged = style_for(owner, name: 'Books', target_kind: 'hashtag', target_hashtag: 'Foo')
      common = style_for(owner, name: 'Common')
      list = Fabricate(:list, account: owner.account, title: 'Reading')

      put :update, params: { surface_kind: 'hashtag', surface_key: '#Foo', style_id: tagged.id }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:surface]).to include(kind: 'hashtag', key: 'foo')
      expect(body_as_json[:status]).to eq('style')

      put :update, params: { surface_kind: 'list', surface_key: list.id.to_s, style_id: common.id }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:surface]).to include(kind: 'list', key: list.id.to_s)
      expect(body_as_json[:status]).to eq('style')
    end

    it 'rejects another user’s style, a disabled style, a mismatched destination, and someone else’s list' do
      other = user_with_role('Owner')
      foreign_style = style_for(other, name: 'Theirs', target_kind: 'group', target_account: group)
      disabled = style_for(owner, name: 'Hidden', target_kind: 'group', target_account: group, enabled: false)
      other_group = Fabricate(:account, username: 'othersquad', actor_type: 'Group')
      aimed_elsewhere = style_for(owner, name: 'Elsewhere', target_kind: 'group', target_account: other_group)
      foreign_list = Fabricate(:list, account: other.account, title: 'Theirs')

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: foreign_style.id }, as: :json
      expect(response).to have_http_status(422)

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: disabled.id }, as: :json
      expect(response).to have_http_status(422)

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: aimed_elsewhere.id }, as: :json
      expect(response).to have_http_status(422)

      put :update, params: { surface_kind: 'list', surface_key: foreign_list.id.to_s, style_id: nil }, as: :json
      expect(response).to have_http_status(422)
      expect(UserPostingContextAssignment.where(user_id: owner.id)).to be_empty
      expect(UserPostingContextAssignment.where(user_id: other.id)).to be_empty
    end

    it 'rejects a non-administrator' do
      member = Fabricate(:user)
      member_token = Fabricate(:accessible_access_token, resource_owner_id: member.id, scopes: 'write')
      allow(controller).to receive(:doorkeeper_token) { member_token }

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: nil }, as: :json

      expect(response).to have_http_status(403)
    end

    it 'rejects a read-only token' do
      style = style_for(owner, target_kind: 'group', target_account: group)
      read_token = Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read')
      allow(controller).to receive(:doorkeeper_token) { read_token }

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: style.id }, as: :json

      expect(response).to have_http_status(403)
      expect(UserPostingContextAssignment.where(user_id: owner.id)).to be_empty
    end

    it 'rejects a write that omits style_id' do
      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s }, as: :json

      expect(response).to have_http_status(400)
      expect(UserPostingContextAssignment.where(user_id: owner.id)).to be_empty
    end

    it 'accepts the write:accounts scope' do
      scoped = Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'write:accounts')
      allow(controller).to receive(:doorkeeper_token) { scoped }

      put :update, params: { surface_kind: 'group', surface_key: group.id.to_s, style_id: nil }, as: :json

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq('none')
    end
  end

  describe 'DELETE #destroy' do
    it 'removes the row and returns unset, including when it was already unset' do
      style = style_for(owner, target_kind: 'group', target_account: group)
      UserPostingContextAssignment.assign!(user: owner, surface_kind: 'group', surface_key: group.id.to_s, style: style)

      delete :destroy, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(status: 'unset', style_id: nil, revision: nil)
      expect(UserPostingContextAssignment.where(user_id: owner.id)).to be_empty

      delete :destroy, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq('unset')
    end

    it 'does not delete another user’s row' do
      other = user_with_role('Owner')
      UserPostingContextAssignment.assign!(user: other, surface_kind: 'group', surface_key: group.id.to_s, style: nil)

      delete :destroy, params: { surface_kind: 'group', surface_key: group.id.to_s }

      expect(response).to have_http_status(200)
      expect(other.user_posting_context_assignments.count).to eq(1)
    end

    it 'rejects an unauthenticated request and a read-only token' do
      allow(controller).to receive(:doorkeeper_token) { nil }
      delete :destroy, params: { surface_kind: 'group', surface_key: group.id.to_s }
      expect(response).to have_http_status(401)

      read_token = Fabricate(:accessible_access_token, resource_owner_id: owner.id, scopes: 'read')
      allow(controller).to receive(:doorkeeper_token) { read_token }
      delete :destroy, params: { surface_kind: 'group', surface_key: group.id.to_s }
      expect(response).to have_http_status(403)
    end
  end
end
