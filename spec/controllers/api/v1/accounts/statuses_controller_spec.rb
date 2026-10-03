require 'rails_helper'

describe Api::V1::Accounts::StatusesController do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    Fabricate(:status, account: user.account)
  end

  describe 'GET #index' do
    it 'returns http success' do
      get :index, params: { account_id: user.account.id, limit: 1 }

      expect(response).to have_http_status(200)
      expect(response.headers['Link'].links.size).to eq(2)
    end

    context 'with only media' do
      it 'returns http success' do
        get :index, params: { account_id: user.account.id, only_media: true }

        expect(response).to have_http_status(200)
      end
    end

    context 'with exclude replies' do
      before do
        Fabricate(:status, account: user.account, thread: Fabricate(:status))
      end

      it 'returns http success' do
        get :index, params: { account_id: user.account.id, exclude_replies: true }

        expect(response).to have_http_status(200)
      end
    end

    context 'with only own pinned' do
      before do
        Fabricate(:status_pin, account: user.account, status: Fabricate(:status, account: user.account))
      end

      it 'returns http success' do
        get :index, params: { account_id: user.account.id, pinned: true }

        expect(response).to have_http_status(200)
      end
    end

    context "with someone else's pinned statuses" do
      let(:account)        { Fabricate(:account, username: 'bob', domain: 'example.com') }
      let(:status)         { Fabricate(:status, account: account) }
      let(:private_status) { Fabricate(:status, account: account, visibility: :private) }
      let!(:pin)           { Fabricate(:status_pin, account: account, status: status) }
      let!(:private_pin)   { Fabricate(:status_pin, account: account, status: private_status) }

      it 'returns http success' do
        get :index, params: { account_id: account.id, pinned: true }
        expect(response).to have_http_status(200)
      end

      context 'when user does not follow account' do
        it 'lists the public status only' do
          get :index, params: { account_id: account.id, pinned: true }
          json = body_as_json
          expect(json.map { |item| item[:id].to_i }).to eq [status.id]
        end
      end

      context 'when user follows account' do
        before do
          user.account.follow!(account)
        end

        it 'lists both the public and the private statuses' do
          get :index, params: { account_id: account.id, pinned: true }
          json = body_as_json
          expect(json.map { |item| item[:id].to_i }.sort).to eq [status.id, private_status.id].sort
        end
      end
    end
  end

  describe 'GET #index min_id pagination' do
    def insert_status(id, account: user.account, **attrs)
      Fabricate(:status, { account: account, id: id, text: "status-#{id}" }.merge(attrs))
    end

    def status_ids
      body_as_json.map { |status| status[:id].to_i }
    end

    def capture_statements(&block)
      statements = []
      callback = lambda do |*_args, payload|
        casted = payload[:type_casted_binds]
        casted = casted.call if casted.respond_to?(:call)
        statements << { sql: payload[:sql].to_s, binds: Array(casted) }
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      statements
    end

    def tuple_statement(statements)
      statements.find { |statement| statement[:sql].include?('(statuses.account_id, statuses.id) >') && statement[:sql].include?('SELECT') }
    end

    def sql_without_tuple(sql)
      sql.gsub('(statuses.account_id, statuses.id) >', '')
    end

    def expect_tuple_lower_bound(statement, account_id:, min_id:)
      sql = statement[:sql]
      expect(sql).to include('(statuses.account_id, statuses.id) >')
      expect(sql).to match(/ORDER BY "statuses"\."account_id" ASC, "statuses"\."id" ASC/)
      expect(sql_without_tuple(sql)).not_to match(/"statuses"\."id" >|statuses\.id >/)

      if sql.include?("(#{account_id}, #{min_id})")
        expect(sql).to include("(statuses.account_id, statuses.id) > (#{account_id}, #{min_id})")
      else
        expect(statement[:binds]).to include(account_id, min_id)
      end
    end

    def expect_max_id_upper_bound(statement, max_id)
      sql = statement[:sql]
      expect(sql).to match(/"statuses"\."id" </)

      return if sql.match?(/"statuses"\."id" < #{max_id}\b/)

      expect(statement[:binds]).to include(max_id)
    end

    def link_param(rel, key)
      href = response.headers['Link']&.find_link(['rel', rel])&.href
      return if href.blank?

      Rack::Utils.parse_query(URI(href).query)[key]
    end

    before do
      [100, 200, 300, 400, 500].each { |id| insert_status(id) }
    end

    it 'returns the statuses immediately above min_id in descending order' do
      statements = capture_statements { get :index, params: { account_id: user.account.id, min_id: 200, limit: 2 } }
      page = tuple_statement(statements)

      expect(response).to have_http_status(200)
      expect(status_ids).to eq [400, 300]
      expect_tuple_lower_bound(page, account_id: user.account.id, min_id: 200)
      expect(link_param('next', 'max_id')).to eq '300'
      expect(link_param('prev', 'min_id')).to eq '400'
      expect(link_param('next', 'limit')).to eq '2'
      expect(link_param('prev', 'limit')).to eq '2'
    end

    it 'keeps min_id and max_id as strict bounds' do
      statements = capture_statements do
        get :index, params: { account_id: user.account.id, min_id: 200, max_id: 500, limit: 2 }
      end
      page = tuple_statement(statements)

      expect(status_ids).to eq [400, 300]
      expect_tuple_lower_bound(page, account_id: user.account.id, min_id: 200)
      expect_max_id_upper_bound(page, 500)
      expect(link_param('next', 'max_id')).to eq '300'
      expect(link_param('prev', 'min_id')).to eq '400'
    end

    it 'ignores since_id when min_id is present' do
      statements = capture_statements do
        get :index, params: { account_id: user.account.id, min_id: 300, since_id: 100, limit: 2 }
      end

      expect(status_ids).to eq [500, 400]
      expect_tuple_lower_bound(tuple_statement(statements), account_id: user.account.id, min_id: 300)
    end

    it 'keeps max_id pagination on the generic id-ordered page' do
      statements = capture_statements { get :index, params: { account_id: user.account.id, max_id: 400, limit: 2 } }

      expect(status_ids).to eq [300, 200]
      expect(statements.join).not_to include('(statuses.account_id, statuses.id) >')
      expect(statements.map { |statement| statement[:sql] }.join("\n")).to match(/ORDER BY "statuses"\."id" DESC/)
    end

    it 'keeps since_id pagination on the generic id-ordered page' do
      statements = capture_statements { get :index, params: { account_id: user.account.id, since_id: 400, limit: 2 } }
      sql = statements.map { |statement| statement[:sql] }.join("\n")

      expect(status_ids.first).to be > 500
      expect(status_ids.last).to eq 500
      expect(sql).not_to include('(statuses.account_id, statuses.id) >')
      expect(sql).to match(/ORDER BY "statuses"\."id" DESC/)
    end

    it 'uses the tuple bound while excluding replies to other accounts' do
      reply = insert_status(350, thread: Fabricate(:status))
      statements = capture_statements do
        get :index, params: { account_id: user.account.id, min_id: 200, limit: 2, exclude_replies: true }
      end
      page = tuple_statement(statements)

      expect(status_ids).to eq [400, 300]
      expect(status_ids).not_to include(reply.id)
      expect_tuple_lower_bound(page, account_id: user.account.id, min_id: 200)
      expect(page[:sql]).to include('statuses.reply = FALSE')
      expect(page[:sql]).to include('statuses.in_reply_to_account_id = statuses.account_id')
    end

    it 'uses the tuple bound while excluding reblogs' do
      reblog = insert_status(350, reblog: Fabricate(:status))
      statements = capture_statements do
        get :index, params: { account_id: user.account.id, min_id: 200, limit: 2, exclude_reblogs: true }
      end
      page = tuple_statement(statements)

      expect(status_ids).to eq [400, 300]
      expect(status_ids).not_to include(reblog.id)
      expect_tuple_lower_bound(page, account_id: user.account.id, min_id: 200)
      expect(page[:sql]).to include('statuses.reblog_of_id IS NULL')
    end

    it 'does not use the tuple bound for an only_media min_id page' do
      media_status = insert_status(450)
      Fabricate(:media_attachment, account: user.account, status: media_status)
      statements = capture_statements do
        get :index, params: { account_id: user.account.id, min_id: 200, limit: 2, only_media: true }
      end

      expect(status_ids).to eq [media_status.id]
      expect(statements.map { |statement| statement[:sql] }.join("\n")).not_to include('(statuses.account_id, statuses.id) >')
    end

    it 'does not use the tuple bound for a tagged min_id page' do
      tag = Fabricate(:tag)
      tagged = insert_status(450)
      tagged.tags << tag
      statements = capture_statements do
        get :index, params: { account_id: user.account.id, min_id: 200, tagged: tag.name }
      end

      expect(status_ids).to eq [tagged.id]
      expect(statements.map { |statement| statement[:sql] }.join("\n")).not_to include('(statuses.account_id, statuses.id) >')
    end

    it 'does not use the tuple bound for a pinned min_id page' do
      pinned = user.account.statuses.find(300)
      Fabricate(:status_pin, account: user.account, status: pinned)
      statements = capture_statements do
        get :index, params: { account_id: user.account.id, min_id: 200, pinned: true }
      end

      expect(status_ids).to include(pinned.id)
      expect(statements.map { |statement| statement[:sql] }.join("\n")).not_to include('(statuses.account_id, statuses.id) >')
    end

    it 'keeps public and unlisted visibility for another account' do
      account = Fabricate(:account)
      insert_status(600, account: account, visibility: :public)
      insert_status(700, account: account, visibility: :private)
      insert_status(800, account: account, visibility: :unlisted)
      insert_status(900, account: account, visibility: :direct)
      insert_status(1000, account: account, visibility: :public)

      statements = capture_statements do
        get :index, params: { account_id: account.id, min_id: 50, limit: 10 }
      end

      expect(status_ids).to eq [1000, 800, 600]
      expect_tuple_lower_bound(tuple_statement(statements), account_id: account.id, min_id: 50)
    end
  end
end
