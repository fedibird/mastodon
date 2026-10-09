# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::StatusesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'poster')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'author')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'write:statuses read:statuses') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  def delegate!(scopes: %w(post), requester: grantee, owner: grantor)
    PostingIdentity::RequestAllowance.permit!(grantor: owner, acct: requester.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: requester, acct: owner.account.username, scopes: scopes, ip: '203.0.113.40')
    PostingIdentity::Approval.call!(approver: owner, token: issued.token)
  end

  describe 'POST #create as a delegated account' do # rubocop:disable Metrics/BlockLength
    it 'publishes a text status owned by the granting account' do
      delegation = delegate!

      post :create, params: { status: 'Hello from B', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }

      status = grantor.account.statuses.last
      audit = PostingIdentityPost.find_by(status_id: status.id)

      expect(response).to have_http_status(200)
      expect(status.text).to eq 'Hello from B'
      expect(status.account_id).to eq grantor.account.id
      expect(grantee.account.statuses).to be_empty
      expect(ActivityPub::TagManager.instance.uri_for(status)).to include("/users/#{grantor.account.username}/")
      expect(audit.grantee_user_id).to eq grantee.id
      expect(audit.delegation_id).to eq delegation.id
      expect(audit.posting_account_id).to eq grantor.account.id
      expect(audit.posted_at).to be_present
    end

    it 'keeps an omitted posting identity on the signed-in account' do
      delegate!

      post :create, params: { status: 'Still me', visibility: 'public' }

      expect(response).to have_http_status(200)
      expect(grantee.account.statuses.last.text).to eq 'Still me'
      expect(grantor.account.statuses).to be_empty
    end

    it 'rejects a forged or ungranted delegated id and a client account id' do
      delegate!
      stranger = Fabricate(:account, username: 'stranger')

      expect do
        post :create, params: { status: 'Stolen', posting_identity_id: "delegated:#{stranger.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      expect do
        post :create, params: { status: 'Stolen', account_id: grantor.account.id, posting_identity_id: "delegated:#{grantor.account.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
    end

    it 'rejects a grant that cannot post, then a revoked or expired grant' do
      delegation = delegate!(scopes: %w(post media))
      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: ['media'])

      expect do
        post :create, params: { status: 'Media only', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: ['post'])
      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation.reload)

      expect do
        post :create, params: { status: 'Revoked', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)
    end

    it 'rejects an expired grant and a suspended or silenced posting account adjusts visibility' do
      delegation = delegate!
      delegation.update_columns(expires_at: 1.minute.ago)

      expect do
        post :create, params: { status: 'Expired', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }
      end.not_to change(Status, :count)

      expect(response).to have_http_status(403)

      delegation.update_columns(expires_at: 30.days.from_now)
      grantor.account.silence!

      post :create, params: { status: 'Quieter', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.visibility).to eq 'unlisted'
    end

    it 'applies the granting account posting limits and does not use the operator default expiry' do
      delegate!
      grantor.settings.prohibited_visibilities = ['public']
      grantee.settings.update(default_expires_in: '1d')

      post :create, params: {
        status: 'Hidden',
        visibility: 'public',
        posting_identity_id: "delegated:#{grantor.account.id}",
      }

      expect(response).to have_http_status(422)
      expect(grantor.account.statuses).to be_empty

      post :create, params: {
        status: 'Followers',
        visibility: 'private',
        posting_identity_id: "delegated:#{grantor.account.id}",
      }

      status = grantor.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.visibility).to eq 'private'
      expect(status.status_expire).to be_nil
    end

    it 'rejects media, polls, replies, quotes, groups, schedules, and expiry' do
      delegate!
      other = Fabricate(:status, account: Fabricate(:account, username: 'quoted'))

      [
        { media_ids: ['1'] },
        { poll: { options: %w(a b) } },
        { in_reply_to_id: other.id },
        { quote_id: other.id },
        { status: 'QT: [https://example.com/users/quoted/statuses/1]' },
        { status: 'hello @quoted' },
        { audience_account_id: other.account_id },
        { circle_id: '1' },
        { visibility: 'direct' },
        { visibility: 'limited' },
        { scheduled_at: 1.hour.from_now.iso8601 },
        { expires_in: 3600 },
        { status_reference_ids: [other.id] },
      ].each do |extra|
        expect do
          post :create, params: extra.reverse_merge(status: 'No', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}")
        end.not_to change(Status, :count)

        expect(response).to have_http_status(422)
      end
    end

    it 'does not let the operator edit or delete the delegated status' do
      delegate!
      post :create, params: { status: 'Owned by B', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }
      status = grantor.account.statuses.last

      put :update, params: { id: status.id, status: 'Changed', posting_identity_id: "delegated:#{grantor.account.id}" }

      expect(response).to have_http_status(403)
      expect(status.reload.text).to eq 'Owned by B'

      delete :destroy, params: { id: status.id }

      expect(response).to have_http_status(404)
      expect(status.reload).to be_present
    end

    it 'separates idempotency keys between the operator, the account owner, and another grantee' do
      delegate!
      request.headers['Idempotency-Key'] = 'same-key'

      post :create, params: { status: 'Once', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }
      first = grantor.account.statuses.last

      expect do
        post :create, params: { status: 'Once', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }
      end.not_to change(Status, :count)

      expect(grantor.account.statuses.last.id).to eq first.id

      post :create, params: { status: 'Own post', visibility: 'public' }

      expect(grantee.account.statuses.last.text).to eq 'Own post'

      other = user_with_role('Owner', account: Fabricate(:account, username: 'other_poster'))
      delegate!(requester: other)
      other_token = Fabricate(:accessible_access_token, resource_owner_id: other.id, scopes: 'write:statuses')
      allow(controller).to receive(:doorkeeper_token) { other_token }
      controller.instance_variable_set(:@current_user, nil)
      request.headers['Idempotency-Key'] = 'same-key'

      post :create, params: { status: 'Other grantee', visibility: 'public', posting_identity_id: "delegated:#{grantor.account.id}" }

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.pluck(:text)).to include('Once', 'Other grantee')
    end

    it 'does not show a private delegated status or its notifications to the operator' do
      delegate!

      post :create, params: { status: 'Just followers', visibility: 'private', posting_identity_id: "delegated:#{grantor.account.id}" }
      status = grantor.account.statuses.last

      expect(Notification.where(account_id: grantee.account.id)).to be_empty

      get :show, params: { id: status.id }

      expect(response).not_to have_http_status(200)
    end
  end
end
