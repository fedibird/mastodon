require 'rails_helper'

RSpec.describe AccountsController, type: :controller do
  render_views

  let(:account) { Fabricate(:user).account }

  shared_examples 'cachable response' do
    it 'does not set cookies' do
      expect(response.cookies).to be_empty
      expect(response.headers['Set-Cookies']).to be nil
    end

    it 'does not set sessions' do
      expect(session).to be_empty
    end

    it 'returns public Cache-Control header' do
      expect(response.headers['Cache-Control']).to include 'public'
    end
  end

  describe 'GET #show' do
    let(:format) { 'html' }

    let!(:status) { Fabricate(:status, account: account) }
    let!(:status_reply) { Fabricate(:status, account: account, thread: Fabricate(:status)) }
    let!(:status_self_reply) { Fabricate(:status, account: account, thread: status) }
    let!(:status_media) { Fabricate(:status, account: account) }
    let!(:status_pinned) { Fabricate(:status, account: account) }
    let!(:status_private) { Fabricate(:status, account: account, visibility: :private) }
    let!(:status_direct) { Fabricate(:status, account: account, visibility: :direct) }
    let!(:status_reblog) { Fabricate(:status, account: account, reblog: Fabricate(:status)) }

    before do
      status_media.media_attachments << Fabricate(:media_attachment, account: account, type: :image)
      account.pinned_statuses << status_pinned
      account.pinned_statuses << status_private
    end

    shared_examples 'preliminary checks' do
      context 'when account is not approved' do
        before do
          account.user.update(approved: false)
        end

        it 'returns http not found' do
          get :show, params: { username: account.username, format: format }
          expect(response).to have_http_status(404)
        end
      end
    end

    context 'as HTML' do
      let(:format) { 'html' }

      it_behaves_like 'preliminary checks'

      context 'when account is permanently suspended' do
        before do
          account.suspend!
          account.deletion_request.destroy
        end

        it 'returns http gone' do
          get :show, params: { username: account.username, format: format }
          expect(response).to have_http_status(410)
        end
      end

      context 'when account is temporarily suspended' do
        before do
          account.suspend!
        end

        it 'returns http forbidden' do
          get :show, params: { username: account.username, format: format }
          expect(response).to have_http_status(403)
        end
      end

      shared_examples 'common response characteristics' do
        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'returns Link header' do
          expect(response.headers['Link'].to_s).to include ActivityPub::TagManager.instance.uri_for(account)
        end

        it 'renders show template' do
          expect(response).to render_template(:show)
        end
      end

      context do
        before do
          get :show, params: { username: account.username, format: format }
        end

        it_behaves_like 'common response characteristics'

        it 'renders public status' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'renders self-reply' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'renders status with media' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'renders reblog' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'renders pinned status' do
          expect(response.body).to include(I18n.t('stream_entries.pinned'))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'does not render reply to someone else' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reply))
        end
      end

      context 'when signed-in' do
        let(:user) { Fabricate(:user) }

        before do
          sign_in(user)
        end

        context 'when user follows account' do
          before do
            user.account.follow!(account)
            get :show, params: { username: account.username, format: format }
          end

          it 'does not render private status' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
          end
        end

        context 'when user is blocked' do
          before do
            account.block!(user.account)
            get :show, params: { username: account.username, format: format }
          end

          it 'renders unavailable message' do
            expect(response.body).to include(I18n.t('accounts.unavailable'))
          end

          it 'does not render public status' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status))
          end

          it 'does not render self-reply' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_self_reply))
          end

          it 'does not render status with media' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_media))
          end

          it 'does not render reblog' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
          end

          it 'does not render pinned status' do
            expect(response.body).to_not include(I18n.t('stream_entries.pinned'))
          end

          it 'does not render private status' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
          end

          it 'does not render direct status' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
          end

          it 'does not render reply to someone else' do
            expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reply))
          end
        end
      end

      context 'with replies' do
        before do
          allow(controller).to receive(:replies_requested?).and_return(true)
          get :show, params: { username: account.username, format: format }
        end

        it_behaves_like 'common response characteristics'

        it 'renders public status' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'renders self-reply' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'renders status with media' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'renders reblog' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'does not render pinned status' do
          expect(response.body).to_not include(I18n.t('stream_entries.pinned'))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'renders reply to someone else' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_reply))
        end
      end

      context 'with media' do
        before do
          allow(controller).to receive(:media_requested?).and_return(true)
          get :show, params: { username: account.username, format: format }
        end

        it_behaves_like 'common response characteristics'

        it 'does not render public status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'does not render self-reply' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'renders status with media' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'does not render reblog' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'does not render pinned status' do
          expect(response.body).to_not include(I18n.t('stream_entries.pinned'))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'does not render reply to someone else' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reply))
        end
      end

      context 'with tag' do
        let(:tag) { Fabricate(:tag) }

        let!(:status_tag) { Fabricate(:status, account: account) }

        before do
          allow(controller).to receive(:tag_requested?).and_return(true)
          status_tag.tags << tag
          get :show, params: { username: account.username, format: format, tag: tag.to_param }
        end

        it_behaves_like 'common response characteristics'

        it 'does not render public status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'does not render self-reply' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'does not render status with media' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'does not render reblog' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'does not render pinned status' do
          expect(response.body).to_not include(I18n.t('stream_entries.pinned'))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'does not render reply to someone else' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reply))
        end

        it 'renders status with tag' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_tag))
        end
      end
    end

    context 'as JSON' do
      let(:authorized_fetch_mode) { false }
      let(:format) { 'json' }

      before do
        allow(controller).to receive(:authorized_fetch_mode?).and_return(authorized_fetch_mode)
      end

      it_behaves_like 'preliminary checks'

      context 'when account is suspended permanently' do
        before do
          account.suspend!
          account.deletion_request.destroy
        end

        it 'returns http gone' do
          get :show, params: { username: account.username, format: format }
          expect(response).to have_http_status(410)
        end
      end

      context 'when account is suspended temporarily' do
        before do
          account.suspend!
        end

        it 'returns http success' do
          get :show, params: { username: account.username, format: format }
          expect(response).to have_http_status(200)
        end
      end

      context do
        before do
          get :show, params: { username: account.username, format: format }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'returns application/activity+json' do
          expect(response.media_type).to eq 'application/activity+json'
        end

        it_behaves_like 'cachable response'

        it 'renders account' do
          json = body_as_json
          expect(json).to include(:id, :type, :preferredUsername, :inbox, :publicKey, :name, :summary)
        end

        it 'includes memorial false and the toot:memorial context' do
          json = body_as_json
          extension = Array(json[:'@context']).find { |item| item.is_a?(Hash) }

          expect(json[:memorial]).to be false
          expect(extension[:memorial]).to eq 'toot:memorial'
        end

        context 'in authorized fetch mode' do
          let(:authorized_fetch_mode) { true }

          it 'returns http unauthorized' do
            expect(response).to have_http_status(401)
          end
        end
      end

      context 'when signed in' do
        let(:user) { Fabricate(:user) }

        before do
          sign_in(user)
          get :show, params: { username: account.username, format: format }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'returns application/activity+json' do
          expect(response.media_type).to eq 'application/activity+json'
        end

        it 'returns public Cache-Control header' do
          expect(response.headers['Cache-Control']).to include 'public'
        end

        it 'renders account' do
          json = body_as_json
          expect(json).to include(:id, :type, :preferredUsername, :inbox, :publicKey, :name, :summary)
        end
      end

      context 'with signature' do
        let(:remote_account) { Fabricate(:account, domain: 'example.com') }

        before do
          allow(controller).to receive(:signed_request_account).and_return(remote_account)
          get :show, params: { username: account.username, format: format }
        end

        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it 'returns application/activity+json' do
          expect(response.media_type).to eq 'application/activity+json'
        end

        it_behaves_like 'cachable response'

        it 'renders account' do
          json = body_as_json
          expect(json).to include(:id, :type, :preferredUsername, :inbox, :publicKey, :name, :summary)
        end

        context 'in authorized fetch mode' do
          let(:authorized_fetch_mode) { true }

          it 'returns http success' do
            expect(response).to have_http_status(200)
          end

          it 'returns application/activity+json' do
            expect(response.media_type).to eq 'application/activity+json'
          end

          it 'returns private Cache-Control header' do
            expect(response.headers['Cache-Control']).to include 'private'
          end

          it 'returns Vary header with Signature' do
            expect(response.headers['Vary']).to include 'Signature'
          end

          it 'renders account' do
            json = body_as_json
            expect(json).to include(:id, :type, :preferredUsername, :inbox, :publicKey, :name, :summary)
          end
        end
      end
    end

    context 'when the account is memorialized' do
      before do
        account.memorialize!
        get :show, params: { username: account.username, format: 'json' }
      end

      it 'returns application/activity+json' do
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq 'application/activity+json'
      end

      it 'includes memorial true' do
        expect(body_as_json[:memorial]).to be true
      end
    end

    context 'as RSS' do
      let(:format) { 'rss' }

      it_behaves_like 'preliminary checks'

      context 'when account is permanently suspended' do
        before do
          account.suspend!
          account.deletion_request.destroy
        end

        it 'returns http gone' do
          get :show, params: { username: account.username, format: format }
          expect(response).to have_http_status(410)
        end
      end

      context 'when account is temporarily suspended' do
        before do
          account.suspend!
        end

        it 'returns http forbidden' do
          get :show, params: { username: account.username, format: format }
          expect(response).to have_http_status(403)
        end
      end

      shared_examples 'common response characteristics' do
        it 'returns http success' do
          expect(response).to have_http_status(200)
        end

        it_behaves_like 'cachable response'
      end

      context do
        before do
          get :show, params: { username: account.username, format: format }
        end

        it_behaves_like 'common response characteristics'

        it 'renders public status' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'renders self-reply' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'renders status with media' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'does not render reblog' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'does not render reply to someone else' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reply))
        end
      end

      context 'with replies' do
        before do
          allow(controller).to receive(:replies_requested?).and_return(true)
          get :show, params: { username: account.username, format: format }
        end

        it_behaves_like 'common response characteristics'

        it 'renders public status' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'renders self-reply' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'renders status with media' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'does not render reblog' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'renders reply to someone else' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_reply))
        end
      end

      context 'with media' do
        before do
          allow(controller).to receive(:media_requested?).and_return(true)
          get :show, params: { username: account.username, format: format }
        end

        it_behaves_like 'common response characteristics'

        it 'does not render public status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'does not render self-reply' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'renders status with media' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'does not render reblog' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'does not render reply to someone else' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reply))
        end
      end

      context 'with tag' do
        let(:tag) { Fabricate(:tag) }

        let!(:status_tag) { Fabricate(:status, account: account) }

        before do
          allow(controller).to receive(:tag_requested?).and_return(true)
          status_tag.tags << tag
          get :show, params: { username: account.username, format: format, tag: tag.to_param }
        end

        it_behaves_like 'common response characteristics'

        it 'does not render public status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status))
        end

        it 'does not render self-reply' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_self_reply))
        end

        it 'does not render status with media' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_media))
        end

        it 'does not render reblog' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reblog.reblog))
        end

        it 'does not render private status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_private))
        end

        it 'does not render direct status' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_direct))
        end

        it 'does not render reply to someone else' do
          expect(response.body).to_not include(ActivityPub::TagManager.instance.url_for(status_reply))
        end

        it 'renders status with tag' do
          expect(response.body).to include(ActivityPub::TagManager.instance.url_for(status_tag))
        end
      end
    end
  end

  describe 'GET #show min_id pagination' do
    let(:account) { Fabricate(:user).account }

    def insert_status(id, **attrs)
      Fabricate(:status, { account: account, id: id, text: "status-#{id}" }.merge(attrs))
    end

    def status_ids
      assigns(:statuses).map { |status| status.id.to_i }
    end

    def capture_sql(&block)
      statements = []
      callback = lambda do |*_args, payload|
        statements << payload[:sql].to_s
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      statements
    end

    def tuple_page_query(queries)
      queries.find { |sql| sql.include?('(statuses.account_id, statuses.id) >') && sql.include?('SELECT') }
    end

    before do
      [100, 200, 300, 400, 500].each { |id| insert_status(id) }
      insert_status(350, reply: true, in_reply_to_account_id: Fabricate(:account).id)
    end

    it 'returns the statuses immediately above min_id in descending order' do
      queries = capture_sql { get :show, params: { username: account.username, min_id: 200 } }
      page_query = tuple_page_query(queries)

      expect(response).to have_http_status(200)
      expect(status_ids).to eq [500, 400, 300]
      expect(page_query).to match(/\(statuses\.account_id, statuses\.id\) > \(#{account.id}, 200\)/)
      expect(page_query).to match(/ORDER BY "statuses"\."account_id" ASC, "statuses"\."id" ASC/)
      expect(page_query).not_to match(/"statuses"\."id" > /)
      expect(assigns(:older_url)).to include('max_id=300')
      expect(assigns(:newer_url)).to be_nil
    end

    it 'keeps min_id and max_id as strict bounds' do
      queries = capture_sql { get :show, params: { username: account.username, min_id: 200, max_id: 500 } }
      page_query = tuple_page_query(queries)

      expect(status_ids).to eq [400, 300]
      expect(page_query).to match(/\(statuses\.account_id, statuses\.id\) > \(#{account.id}, 200\)/)
      expect(page_query).to match(/"statuses"\."id" < 500/)
      expect(page_query).to match(/ORDER BY "statuses"\."account_id" ASC, "statuses"\."id" ASC/)
      expect(page_query).not_to match(/"statuses"\."id" > /)
      expect(assigns(:older_url)).to include('max_id=300')
      expect(assigns(:newer_url)).to include('min_id=400')
    end

    it 'includes replies on the with_replies min_id scan' do
      allow(controller).to receive(:replies_requested?).and_return(true)
      queries = capture_sql { get :show, params: { username: account.username, min_id: 200 } }

      expect(status_ids).to eq [500, 400, 350, 300]
      expect(tuple_page_query(queries)).to match(/ORDER BY "statuses"\."account_id" ASC, "statuses"\."id" ASC/)
      expect(tuple_page_query(queries)).not_to match(/statuses\.reply = FALSE/)
    end

    it 'keeps max_id pagination on the id-ordered page' do
      queries = capture_sql { get :show, params: { username: account.username, max_id: 400 } }

      expect(status_ids).to eq [300, 200, 100]
      expect(queries.join("\n")).not_to include('(statuses.account_id, statuses.id) >')
      expect(queries.join("\n")).to match(/ORDER BY "statuses"\."id" DESC/)
    end

    it 'does not use the tuple bound for a tagged min_id page' do
      tag = Fabricate(:tag)
      tagged = insert_status(450)
      tagged.tags << tag
      allow(controller).to receive(:tag_requested?).and_return(true)

      queries = capture_sql do
        get :show, params: { username: account.username, tag: tag.to_param, min_id: 200 }
      end

      expect(status_ids).to eq [450]
      expect(queries.join("\n")).not_to include('(statuses.account_id, statuses.id) >')
    end
  end
end
