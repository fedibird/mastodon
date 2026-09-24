# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::StatusesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:app)   { Fabricate(:application, name: 'Test app', website: 'http://testapp.com') }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, application: app, scopes: scopes) }

  context 'with an oauth token' do # rubocop:disable Metrics/BlockLength
    before do
      allow(controller).to receive(:doorkeeper_token) { token }
    end

    describe 'GET #show' do
      let(:scopes) { 'read:statuses' }
      let(:status) { Fabricate(:status, account: user.account) }

      it 'returns http success' do
        get :show, params: { id: status.id }
        expect(response).to have_http_status(200)
      end

      it 'returns canonical filtered FilterResult without filter_results or searchable_text' do
        author = Fabricate(:account)
        filtered_status = Fabricate(:status, account: author, text: "hello foo\nhttps://example.com/filter-url-test")
        filter = Fabricate(:custom_filter, account: user.account, phrase: 'foo', context: %w(home notifications public thread account))
        Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: 'foo')

        get :show, params: { id: filtered_status.id }
        body = body_as_json

        expect(response).to have_http_status(200)
        expect(body).not_to have_key(:filter_results)
        expect(body).not_to have_key(:_fedibird_searchable_text)
        expect(body[:filtered]).to contain_exactly(
          include(
            filter: include(id: filter.id.to_s, title: 'foo', filter_action: 'warn'),
            keyword_matches: include('foo')
          )
        )
      end

      it 'matches an ordinary URL as a keyword without exposing searchable_text' do
        author = Fabricate(:account)
        filtered_status = Fabricate(:status, account: author, text: "URL CHECK\nhttps://example.com/filter-url-test")
        filter = Fabricate(:custom_filter, account: user.account, phrase: 'urls', context: %w(home notifications public thread account))
        Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: 'example.com')

        get :show, params: { id: filtered_status.id }
        body = body_as_json

        expect(response).to have_http_status(200)
        expect(filtered_status.searchable_text).not_to include('example.com')
        expect(body[:filtered]).to contain_exactly(
          include(
            filter: include(id: filter.id.to_s, title: 'urls', filter_action: 'warn'),
            keyword_matches: include('example.com')
          )
        )
        expect(body).not_to have_key(:filter_results)
        expect(body).not_to have_key(:_fedibird_searchable_text)
      end
    end

    describe 'GET #context' do
      let(:scopes) { 'read:statuses' }
      let(:status) { Fabricate(:status, account: user.account) }

      before do
        Fabricate(:status, account: user.account, thread: status)
      end

      it 'returns http success' do
        get :context, params: { id: status.id }
        expect(response).to have_http_status(200)
      end
    end

    describe 'POST #create' do
      let(:scopes) { 'write:statuses' }

      context do
        before do
          post :create, params: { status: 'Hello world' }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'returns rate limit headers' do
          expect(response.headers['X-RateLimit-Limit']).to eq RateLimiter::FAMILIES[:statuses][:limit].to_s
          expect(response.headers['X-RateLimit-Remaining']).to eq (RateLimiter::FAMILIES[:statuses][:limit] - 1).to_s
        end
      end

      context 'with an allowed mention' do
        let!(:alice) { Fabricate(:account, username: 'alice') }

        before do
          post :create, params: { status: '@alice hello', allowed_mentions: [alice.id] }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end
      end

      context 'without an allow-list' do
        let!(:alice) { Fabricate(:account, username: 'alice') }
        let!(:bob)   { Fabricate(:account, username: 'bob') }

        before do
          post :create, params: { status: '@alice hello @bob' }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end
      end

      context 'with a safeguard' do
        let!(:alice) { Fabricate(:account, username: 'alice') }
        let!(:bob)   { Fabricate(:account, username: 'bob') }

        before do
          post :create, params: { status: '@alice hm, @bob is really annoying lately', allowed_mentions: [alice.id] }
        end

        it 'returns http unprocessable entity' do
          expect(response).to have_http_status(422)
          expect(response.media_type).to eq 'application/json'
        end

        it 'returns the unexpected account' do
          expect(body_as_json[:error]).to eq 'Post would be sent to unexpected accounts'
          expect(body_as_json[:unexpected_accounts].map { |a| a.slice(:id, :acct) }).to eq [{ id: bob.id.to_s, acct: bob.acct }]
        end
      end

      context 'with missing parameters' do
        before do
          post :create, params: {}
        end

        it 'returns http unprocessable entity' do
          expect(response).to have_http_status(422)
        end

        it 'returns rate limit headers' do
          expect(response.headers['X-RateLimit-Limit']).to eq RateLimiter::FAMILIES[:statuses][:limit].to_s
        end
      end

      context 'when exceeding rate limit' do
        before do
          rate_limiter = RateLimiter.new(user.account, family: :statuses)
          300.times { rate_limiter.record! }
          post :create, params: { status: 'Hello world' }
        end

        it 'returns http too many requests' do
          expect(response).to have_http_status(429)
        end

        it 'returns rate limit headers' do
          expect(response.headers['X-RateLimit-Limit']).to eq RateLimiter::FAMILIES[:statuses][:limit].to_s
          expect(response.headers['X-RateLimit-Remaining']).to eq '0'
        end
      end
    end

    describe 'PUT #update' do # rubocop:disable Metrics/BlockLength
      let(:scopes) { 'write:statuses' }
      let(:status) { Fabricate(:status, account: user.account, text: 'original', visibility: :unlisted, searchability: :private) }

      before do
        allow(DistributionWorker).to receive(:perform_async)
        allow(ActivityPub::StatusUpdateDistributionWorker).to receive(:perform_async)
        allow(LinkCrawlWorker).to receive(:perform_async)
      end

      it 'returns the edited status and edited_at without replacing updated_at' do
        put :update, params: { id: status.id, status: 'edited text', spoiler_text: 'cw', sensitive: true, language: 'en' }

        expect(response).to have_http_status(200)
        expect(body_as_json[:content]).to include('edited text')
        expect(body_as_json[:spoiler_text]).to eq 'cw'
        expect(body_as_json[:sensitive]).to be true
        expect(body_as_json[:language]).to eq 'en'
        expect(body_as_json[:edited_at]).to be_present
        expect(body_as_json).to have_key(:updated_at)
        expect(body_as_json[:visibility]).to eq 'unlisted'
      end

      it 'ignores quote, visibility, searchability, and expiry parameters' do
        quoted = Fabricate(:status, visibility: :public)
        status.update!(quote_id: quoted.id)
        expire = StatusExpire.create!(status: status, expires_at: 3.days.from_now.change(usec: 0), action: :delete)

        put :update, params: {
          id: status.id,
          status: 'edited text',
          visibility: 'public',
          quote_id: Fabricate(:status).id,
          searchability: 'public',
          circle_id: 12,
          expires_in: 60,
        }

        status.reload
        expect(response).to have_http_status(200)
        expect(status.quote_id).to eq quoted.id
        expect(status.visibility).to eq 'unlisted'
        expect(status.searchability).to eq 'private'
        expect(expire.reload.action).to eq 'delete'
        expect(body_as_json[:quote_id]).to eq quoted.id.to_s
      end

      it 'returns http not found for another account' do
        other = Fabricate(:status, text: 'theirs')

        put :update, params: { id: other.id, status: 'nope' }

        expect(response).to have_http_status(404)
        expect(other.reload.text).to eq 'theirs'
      end

      it 'returns the same status when the edit is a no-op' do
        put :update, params: { id: status.id, status: 'original' }

        expect(response).to have_http_status(200)
        expect(body_as_json[:edited_at]).to be_nil
        expect(status.reload.edits).to be_empty
      end

      it 'rejects the edit while posting is disabled' do
        user.settings.disable_post = true

        put :update, params: { id: status.id, status: 'edited text' }

        expect(response).to have_http_status(403)
        expect(status.reload.text).to eq 'original'
        expect(status.edited_at).to be_nil
        expect(status.edits).to be_empty
        expect(DistributionWorker).not_to have_received(:perform_async)
        expect(ActivityPub::StatusUpdateDistributionWorker).not_to have_received(:perform_async)
      end

      context 'with a read scope' do
        let(:scopes) { 'read:statuses' }

        it 'returns http forbidden' do
          put :update, params: { id: status.id, status: 'edited text' }

          expect(response).to have_http_status(403)
          expect(status.reload.text).to eq 'original'
        end
      end
    end

    describe 'DELETE #destroy' do
      let(:scopes) { 'write:statuses' }
      let(:status) { Fabricate(:status, account: user.account) }

      before do
        post :destroy, params: { id: status.id }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'removes the status' do
        expect(Status.find_by(id: status.id)).to be nil
      end
    end
  end

  context 'without an oauth token' do
    before do
      allow(controller).to receive(:doorkeeper_token) { nil }
    end

    context 'with a private status' do
      let(:status) { Fabricate(:status, account: user.account, visibility: :private) }

      describe 'GET #show' do
        it 'returns http unautharized' do
          get :show, params: { id: status.id }
          expect(response).to have_http_status(404)
        end
      end

      describe 'GET #context' do
        before do
          Fabricate(:status, account: user.account, thread: status)
        end

        it 'returns http unautharized' do
          get :context, params: { id: status.id }
          expect(response).to have_http_status(404)
        end
      end
    end

    context 'with a public status' do
      let(:status) { Fabricate(:status, account: user.account, visibility: :public) }

      describe 'GET #show' do
        it 'returns http success' do
          get :show, params: { id: status.id }
          expect(response).to have_http_status(200)
        end
      end

      describe 'GET #context' do
        before do
          Fabricate(:status, account: user.account, thread: status)
        end

        it 'returns http success' do
          get :context, params: { id: status.id }
          expect(response).to have_http_status(200)
        end
      end
    end
  end
end
