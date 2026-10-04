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

  describe 'GET #index tagged' do
    let(:author) { Fabricate(:account, username: 'tagged_api_author') }
    let(:tag) { Fabricate(:tag, name: 'apitag') }
    let(:viewer_token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:statuses') }

    def insert_status(id, account: author, **attrs)
      Fabricate(:status, { account: account, id: id, text: "status-#{id}", visibility: :public }.merge(attrs))
    end

    def tag_status(status, hashtag = tag)
      status.tags << hashtag
      status
    end

    def status_ids
      body_as_json.map { |status| status[:id].to_i }
    end

    def capture_statements(&block)
      statements = []
      callback = lambda do |*_args, payload|
        statements << payload[:sql].to_s
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      statements
    end

    def sql_text(statements)
      statements.join("\n")
    end

    def page_sql(statements)
      statements.find { |statement| statement.include?('WITH matched_ids AS MATERIALIZED') }.to_s
    end

    def cte_and_outer(statements)
      page_sql(statements).split(') SELECT statuses.*', 2)
    end

    def link_param(rel, key)
      href = response.headers['Link']&.find_link(['rel', rel])&.href
      return if href.blank?

      Rack::Utils.parse_query(URI(href).query)[key]
    end

    before do
      allow(controller).to receive(:doorkeeper_token) { viewer_token }
    end

    it 'returns tagged statuses in id order without reading statuses.* inside the CTE' do
      tag_status(insert_status(10))
      tag_status(insert_status(30))
      tag_status(insert_status(20))
      insert_status(40)
      tag_status(insert_status(50, account: Fabricate(:account)))

      statements = capture_statements do
        get :index, params: { account_id: author.id, tagged: tag.name }
      end
      sql = page_sql(statements)
      cte, = cte_and_outer(statements)

      expect(response).to have_http_status(200)
      expect(status_ids).to eq [30, 20, 10]
      expect(body_as_json.map { |status| status[:content] }).to eq ['<p>status-30</p>', '<p>status-20</p>', '<p>status-10</p>']
      expect(sql).to include('WITH matched_ids AS MATERIALIZED')
      expect(cte).to match(/SELECT "statuses"\."id"/)
      expect(cte).not_to include('statuses.*')
      expect(sql.scan(/\bLIMIT\b/).size).to eq 1
      expect(cte).not_to match(/\bLIMIT\b/i)
    end

    it 'returns an empty list for an unknown tag without a CTE' do
      tag_status(insert_status(10))

      statements = capture_statements do
        get :index, params: { account_id: author.id, tagged: "missing' OR 1=1 --" }
      end

      expect(status_ids).to eq []
      expect(sql_text(statements)).not_to include('matched_ids')
      expect(sql_text(statements)).not_to include('AS MATERIALIZED')
    end

    it 'drops replies to other accounts after the intersection and still fills the limit' do
      stranger = Fabricate(:account)
      [100, 200, 300, 400, 500].each { |id| tag_status(insert_status(id)) }
      25.times do |index|
        parent = Fabricate(:status, account: stranger, text: "parent-#{index}")
        tag_status(insert_status(1_000 + index, thread: parent))
      end

      statements = capture_statements do
        get :index, params: { account_id: author.id, tagged: tag.name, exclude_replies: true, limit: 5 }
      end
      cte, outer = cte_and_outer(statements)

      expect(status_ids).to eq [500, 400, 300, 200, 100]
      expect(cte).not_to include('statuses.reply')
      expect(cte).not_to match(/\bLIMIT\b/i)
      expect(outer).to include('statuses.reply = FALSE')
      expect(outer).to include('statuses.in_reply_to_account_id = statuses.account_id')
      expect(outer).to include('LIMIT 5')
    end

    it 'keeps a self-reply when exclude_replies is set' do
      tag_status(insert_status(10, thread: Fabricate(:status, account: Fabricate(:account))))
      tag_status(insert_status(20, thread: Fabricate(:status, account: author)))
      tag_status(insert_status(30))

      get :index, params: { account_id: author.id, tagged: tag.name, exclude_replies: true }

      expect(status_ids).to eq [30, 20]
    end

    it 'applies exclude_reblogs outside the id intersection' do
      tag_status(insert_status(10, account: user.account))
      tag_status(insert_status(20, account: user.account, reblog: Fabricate(:status)))
      tag_status(insert_status(30, account: user.account))

      statements = capture_statements do
        get :index, params: { account_id: user.account.id, tagged: tag.name, exclude_reblogs: true }
      end
      cte, outer = cte_and_outer(statements)

      expect(status_ids).to eq [30, 10]
      expect(cte).not_to include('reblog_of_id IS NULL')
      expect(outer).to include('statuses.reblog_of_id IS NULL')
    end

    it 'applies exclude_replies and exclude_reblogs together' do
      tag_status(insert_status(10))
      tag_status(insert_status(20, thread: Fabricate(:status, account: Fabricate(:account))))
      tag_status(insert_status(30, reblog: Fabricate(:status)))
      tag_status(insert_status(40))

      get :index, params: { account_id: author.id, tagged: tag.name, exclude_replies: true, exclude_reblogs: true }

      expect(status_ids).to eq [40, 10]
    end

    it 'pages with max_id and since_id inside the id scope' do
      [10, 20, 30, 40, 50].each { |id| tag_status(insert_status(id)) }

      get :index, params: { account_id: author.id, tagged: tag.name, max_id: 40, limit: 2 }
      expect(status_ids).to eq [30, 20]
      expect(link_param('next', 'max_id')).to eq '20'

      get :index, params: { account_id: author.id, tagged: tag.name, since_id: 20, limit: 2 }
      expect(status_ids).to eq [50, 40]
    end

    it 'pages min_id in descending order and ignores since_id' do
      [10, 20, 30, 40, 50].each { |id| tag_status(insert_status(id)) }

      get :index, params: { account_id: author.id, tagged: tag.name, min_id: 20, limit: 2 }
      expect(status_ids).to eq [40, 30]
      expect(link_param('prev', 'min_id')).to eq '40'
      expect(link_param('next', 'max_id')).to eq '30'

      get :index, params: { account_id: author.id, tagged: tag.name, min_id: 20, max_id: 50, limit: 2 }
      expect(status_ids).to eq [40, 30]

      get :index, params: { account_id: author.id, tagged: tag.name, min_id: 20, since_id: 40, limit: 2 }
      expect(status_ids).to eq [40, 30]
    end

    it 'supplements min_id pages when replies would otherwise consume the limit' do
      stranger = Fabricate(:account)
      tag_status(insert_status(100))
      tag_status(insert_status(200, thread: Fabricate(:status, account: stranger)))
      tag_status(insert_status(300))
      tag_status(insert_status(400, thread: Fabricate(:status, account: stranger)))
      tag_status(insert_status(500))

      get :index, params: { account_id: author.id, tagged: tag.name, min_id: 100, exclude_replies: true, limit: 2 }

      expect(status_ids).to eq [500, 300]
    end

    it 'returns the newest page in id descending order' do
      25.times { |index| tag_status(insert_status(index + 1)) }

      get :index, params: { account_id: author.id, tagged: tag.name, limit: 20 }

      expect(status_ids).to eq (6..25).to_a.reverse
    end

    it 'shows an anonymous viewer only public and unlisted tagged statuses' do
      allow(controller).to receive(:doorkeeper_token).and_return(nil)
      tag_status(insert_status(10, visibility: :public))
      tag_status(insert_status(20, visibility: :unlisted))
      tag_status(insert_status(30, visibility: :private))
      tag_status(insert_status(40, visibility: :direct))
      tag_status(insert_status(50, visibility: :limited))
      tag_status(insert_status(60, visibility: :personal))

      get :index, params: { account_id: author.id, tagged: tag.name }

      expect(status_ids).to eq [20, 10]
    end

    it 'shows the author their own limited, personal, and direct tagged statuses' do
      tag_status(insert_status(10, account: user.account, visibility: :direct))
      tag_status(insert_status(20, account: user.account, visibility: :limited))
      tag_status(insert_status(30, account: user.account, visibility: :personal))
      tag_status(insert_status(40, account: user.account, visibility: :mutual))

      get :index, params: { account_id: user.account.id, tagged: tag.name }

      expect(status_ids).to eq [40, 30, 20, 10]
    end

    it 'hides personal tagged statuses when hide_personal_from_account is set' do
      user.settings.hide_personal_from_account = true
      tag_status(insert_status(10, account: user.account, visibility: :public))
      tag_status(insert_status(20, account: user.account, visibility: :personal))

      get :index, params: { account_id: user.account.id, tagged: tag.name }

      expect(status_ids).to eq [10]
    end

    context 'when the viewer is not the author' do
      let(:viewer) { user.account }

      it 'shows private tagged statuses to a follower only' do
        tag_status(insert_status(10, visibility: :public))
        tag_status(insert_status(20, visibility: :private))

        get :index, params: { account_id: author.id, tagged: tag.name }
        expect(status_ids).to eq [10]

        viewer.follow!(author)
        get :index, params: { account_id: author.id, tagged: tag.name }
        expect(status_ids).to eq [20, 10]
      end

      it 'shows a tagged status the viewer is mentioned in and hides other direct statuses' do
        visible = tag_status(insert_status(10, visibility: :direct))
        hidden = tag_status(insert_status(20, visibility: :direct))
        limited = tag_status(insert_status(30, visibility: :limited))
        Fabricate(:mention, account: viewer, status: visible)
        Fabricate(:mention, account: viewer, status: limited)

        get :index, params: { account_id: author.id, tagged: tag.name }

        expect(status_ids).to include(visible.id, limited.id)
        expect(status_ids).not_to include(hidden.id)
      end

      it 'keeps the permission reblog exclusion in front of exclude_reblogs' do
        blocked = Fabricate(:account)
        viewer.block!(blocked)
        visible = tag_status(insert_status(10))
        hidden = tag_status(insert_status(20, reblog: Fabricate(:status, account: blocked, visibility: :public)))

        get :index, params: { account_id: author.id, tagged: tag.name }

        expect(status_ids).to eq [visible.id]
        expect(status_ids).not_to include(hidden.id)
      end
    end

    it 'keeps only_media on the existing relation path' do
      media = tag_status(insert_status(20))
      Fabricate(:media_attachment, account: author, status: media)
      tag_status(insert_status(30))

      statements = capture_statements do
        get :index, params: { account_id: author.id, tagged: tag.name, only_media: true }
      end

      expect(status_ids).to eq [media.id]
      expect(sql_text(statements)).not_to include('AS MATERIALIZED')
    end

    it 'keeps pinned on the existing relation path' do
      pinned = tag_status(insert_status(10))
      tag_status(insert_status(20))
      Fabricate(:status_pin, account: author, status: pinned)

      statements = capture_statements do
        get :index, params: { account_id: author.id, tagged: tag.name, pinned: true }
      end

      expect(status_ids).to eq [pinned.id]
      expect(sql_text(statements)).not_to include('AS MATERIALIZED')
    end
  end
end
