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

  describe 'GET #show tagged HTML id-first' do
    let(:tag) { Fabricate(:tag, name: 'htmltag') }
    let(:other_tag) { Fabricate(:tag, name: 'othertag') }
    let(:other_account) { Fabricate(:account) }

    def insert_status(id, status_account: account, **attrs)
      Fabricate(:status, { account: status_account, id: id, text: "status-#{id}", visibility: :public }.merge(attrs))
    end

    def tag_status(status, hashtag = tag)
      status.tags << hashtag
      status
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

    def matched_queries(statements)
      statements.select { |sql| sql.include?('WITH matched_ids AS MATERIALIZED') }
    end

    def page_sql(statements)
      matched_queries(statements).find { |sql| sql.match?(/\bLIMIT 20\b/) }.to_s
    end

    def boundary_queries(statements)
      matched_queries(statements).select { |sql| sql.match?(/\bLIMIT 1\b/) }
    end

    def cte_of(sql)
      sql.split(') SELECT statuses.*', 2).first.to_s
    end

    def legacy_wide_tagged_queries(statements)
      statements.select do |sql|
        sql.include?('FROM "statuses"') && sql.include?('statuses_tags') && !sql.include?('matched_ids')
      end
    end

    def tag_lookup_count(statements)
      statements.count { |sql| sql.include?('LOWER("tags"."name")') }
    end

    def get_tagged(tag_name: tag.to_param, media: false, format: 'html', **extra)
      suffix = format == 'html' ? '' : ".#{format}"
      @request.path = "/@#{account.username}/tagged/#{tag_name}#{'/media' if media}#{suffix}"
      get :show, params: { username: account.username, tag: tag_name, format: format }.merge(extra)
    end

    def expect_deferred_tagged_sql(sql, limit:, order:)
      cte, outer = sql.split(') SELECT statuses.*', 2)

      expect(sql).to include('WITH matched_ids AS MATERIALIZED')
      expect(sql).to include('SELECT statuses.*')
      expect(sql.index('SELECT statuses.*')).to be > sql.index('WITH matched_ids')
      expect(sql).to include('INNER JOIN matched_ids ON matched_ids.id = statuses.id')
      expect(cte).to match(/SELECT "statuses"\."id"/)
      expect(cte).to include(%("statuses"."account_id" = #{account.id}))
      expect(cte).to include(%("statuses_tags"."tag_id" = #{tag.id}))
      expect(cte).to match(/"statuses"\."visibility" IN \(0, 1\)/)
      expect(cte).not_to include('statuses.reply')
      expect(cte).not_to include('reblog_of_id')
      expect(cte).not_to match(/\bLIMIT\b/i)
      expect(cte).to match(/ORDER BY "statuses"\."id" #{order}/)
      expect(cte).not_to include('statuses.*')
      expect(outer).to include('statuses.reply = FALSE')
      expect(outer).to include('statuses.in_reply_to_account_id = statuses.account_id')
      expect(outer).to include("ORDER BY statuses.id #{order}")
      expect(outer).to include("LIMIT #{limit}")
      expect(sql.scan(/\bLIMIT\b/).size).to eq 1
    end

    def create_decoys
      insert_status(9_100)
      insert_status(9_200).tags << other_tag
      tag_status(insert_status(9_300, status_account: other_account))
    end

    it 'returns only this account and this tag from an id-first page' do
      tag_status(insert_status(10))
      tag_status(insert_status(30))
      tag_status(insert_status(20))
      create_decoys

      statements = capture_sql { get_tagged }
      sql = page_sql(statements)

      expect(response).to have_http_status(200)
      expect(status_ids).to eq [30, 20, 10]
      expect_deferred_tagged_sql(sql, limit: 20, order: 'DESC')
      expect(legacy_wide_tagged_queries(statements)).to be_empty
      expect(tag_lookup_count(statements)).to eq 1
    end

    it 'shows public and unlisted tagged statuses and hides the rest from a follower' do
      tag_status(insert_status(10, visibility: :public))
      tag_status(insert_status(20, visibility: :unlisted))
      tag_status(insert_status(30, visibility: :private))
      tag_status(insert_status(40, visibility: :direct))
      tag_status(insert_status(50, visibility: :limited))
      tag_status(insert_status(60, visibility: :personal))
      insert_status(70, visibility: :public)
      tag_status(insert_status(80, status_account: other_account, visibility: :private))

      follower = Fabricate(:user)
      follower.account.follow!(account)
      sign_in(follower)

      get_tagged

      expect(status_ids).to eq [20, 10]
    end

    it 'drops replies to other accounts and keeps self-replies' do
      stranger = Fabricate(:account)
      parent = insert_status(1_000)
      tag_status(insert_status(10, thread: parent))
      tag_status(insert_status(20, thread: Fabricate(:status, account: stranger)))
      tag_status(insert_status(30))
      insert_status(40)

      statements = capture_sql { get_tagged }
      _cte, outer = page_sql(statements).split(') SELECT statuses.*', 2)

      expect(status_ids).to eq [30, 10]
      expect(cte_of(page_sql(statements))).not_to include('statuses.reply')
      expect(outer).to include('statuses.reply = FALSE')
      expect(outer).to include('statuses.in_reply_to_account_id = statuses.account_id')
    end

    it 'keeps tagged reblogs' do
      tag_status(insert_status(10))
      tag_status(insert_status(20, reblog: Fabricate(:status)))

      statements = capture_sql { get_tagged }

      expect(status_ids).to eq [20, 10]
      expect(cte_of(page_sql(statements))).not_to include('reblog_of_id IS NULL')
    end

    it 'returns the newest page in id order with the limit after reply filtering' do
      25.times { |index| tag_status(insert_status(index + 1)) }
      create_decoys

      statements = capture_sql { get_tagged }
      sql = page_sql(statements)
      cte, outer = sql.split(') SELECT statuses.*', 2)

      expect(status_ids).to eq (6..25).to_a.reverse
      expect_deferred_tagged_sql(sql, limit: 20, order: 'DESC')
      expect(cte).not_to match(/\bLIMIT\b/i)
      expect(outer).to include('LIMIT 20')
    end

    it 'pages with max_id inside the id scope' do
      [100, 200, 300, 400, 500].each { |id| tag_status(insert_status(id)) }
      insert_status(150).tags << other_tag
      insert_status(250)
      tag_status(insert_status(350, status_account: other_account))

      get_tagged(max_id: 400)

      expect(status_ids).to eq [300, 200, 100]
    end

    it 'pages min_id as the following ids reversed' do
      [100, 200, 300, 400, 500].each { |id| tag_status(insert_status(id)) }
      insert_status(250)
      insert_status(350).tags << other_tag
      tag_status(insert_status(450, status_account: other_account))

      statements = capture_sql { get_tagged(min_id: 200) }
      sql = page_sql(statements)

      expect(status_ids).to eq [500, 400, 300]
      expect(cte_of(sql)).to match(/"statuses"\."id" > 200/)
      expect(cte_of(sql)).to match(/ORDER BY "statuses"\."id" ASC/)
      expect(cte_of(sql)).not_to include('statuses.reply')
      expect(cte_of(sql)).not_to match(/\bLIMIT\b/i)
      expect(sql).to match(/ORDER BY statuses\.id ASC/)
      expect(sql).to match(/\bLIMIT 20\b/)
    end

    context 'with more than one page' do
      before do
        45.times { |index| tag_status(insert_status(index + 1)) }
        create_decoys
      end

      it 'links only older on the newest page and probes with id-first queries' do
        statements = capture_sql { get_tagged }
        older, newer = boundary_queries(statements).partition { |sql| sql.include?('"id" < 26') }

        expect(status_ids).to eq (26..45).to_a.reverse
        expect(assigns(:older_url)).to include('max_id=26')
        expect(assigns(:newer_url)).to be_nil
        expect(legacy_wide_tagged_queries(statements)).to be_empty
        expect(boundary_queries(statements).size).to eq 2
        expect_deferred_tagged_sql(older.first, limit: 1, order: 'DESC')
        expect(older.first).to include('"id" < 26')
        expect_deferred_tagged_sql(newer.first, limit: 1, order: 'ASC')
        expect(newer.first).to include('"id" > 45')
        expect(tag_lookup_count(statements)).to eq 1
      end

      it 'links older and newer on a middle page' do
        statements = capture_sql { get_tagged(max_id: 26) }

        expect(status_ids).to eq (6..25).to_a.reverse
        expect(assigns(:older_url)).to include('max_id=6')
        expect(assigns(:newer_url)).to include('min_id=25')
        expect(legacy_wide_tagged_queries(statements)).to be_empty
        expect(boundary_queries(statements).size).to eq 2
        expect(boundary_queries(statements).join("\n")).to include('"id" < 6')
        expect(boundary_queries(statements).join("\n")).to include('"id" > 25')
      end

      it 'links only newer on the oldest page' do
        statements = capture_sql { get_tagged(max_id: 6) }

        expect(status_ids).to eq [5, 4, 3, 2, 1]
        expect(assigns(:older_url)).to be_nil
        expect(assigns(:newer_url)).to include('min_id=5')
        expect(legacy_wide_tagged_queries(statements)).to be_empty
        expect(boundary_queries(statements).size).to eq 2
        expect(boundary_queries(statements).join("\n")).to include('"id" < 1')
        expect(boundary_queries(statements).join("\n")).to include('"id" > 5')
      end
    end

    it 'returns nothing for an unknown tag and does not run the intersection' do
      kept = tag_status(insert_status(10))
      insert_status(20)

      statements = capture_sql { get_tagged(tag_name: 'missing-html-tag') }

      expect(status_ids).to eq []
      expect(status_ids).not_to include(kept.id)
      expect(statements.join("\n")).not_to include('matched_ids')
      expect(statements.join("\n")).not_to include('AS MATERIALIZED')
    end

    it 'keeps tagged media on the existing path' do
      tagged_media = tag_status(insert_status(10))
      tagged_media.media_attachments << Fabricate(:media_attachment, account: account, type: :image)
      tag_status(insert_status(20))
      plain_media = insert_status(30)
      plain_media.media_attachments << Fabricate(:media_attachment, account: account, type: :image)

      statements = capture_sql { get_tagged(media: true) }

      expect(status_ids).to eq [10]
      expect(statements.join("\n")).not_to include('matched_ids')
      expect(statements.join("\n")).not_to include('AS MATERIALIZED')
    end

    it 'leaves tagged RSS on the existing relation' do
      tag_status(insert_status(10))
      insert_status(20)

      statements = capture_sql { get_tagged(format: 'rss') }

      expect(assigns(:statuses).map { |status| status.id.to_i }).to eq [10]
      expect(statements.join("\n")).not_to include('matched_ids')
    end
  end
end
