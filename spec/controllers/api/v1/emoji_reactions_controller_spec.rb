# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Api::V1::EmojiReactionsController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:now) { Time.current }

  def authorize_read!
    allow(controller).to receive(:doorkeeper_token) do
      Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:favourites')
    end
  end

  def insert_reaction(id:, status:, name: '👍', account: user.account)
    row = {
      id: id,
      account_id: account.id,
      status_id: status.id,
      name: name,
      created_at: now,
      updated_at: now,
    }
    EmojiReaction.insert_all!([row])
  end

  def status_ids
    body_as_json.map { |status| status[:id] }
  end

  def capture_sql(&block)
    capture_statements(&block).map { |statement| statement[:sql] }
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

  def candidate_queries(queries)
    queries.select { |sql| sql.include?('NOT EXISTS') && sql.include?('earlier.id') }
  end

  def reaction_lookup_queries(queries)
    queries.select { |sql| sql.match?(/"emoji_reactions"\."id" IN \(/) && sql.exclude?('NOT EXISTS') }
  end

  def in_list_size(sql)
    sql[/"emoji_reactions"\."id" IN \(([^)]*)\)/, 1].to_s.split(',').size
  end

  def link_param(rel, key)
    href = response.headers['Link']&.find_link(['rel', rel])&.href
    return if href.blank?

    Rack::Utils.parse_query(URI(href).query)[key]
  end

  describe 'GET #index' do
    context 'without token' do
      it 'returns http unauthorized' do
        get :index

        expect(response).to have_http_status :unauthorized
      end
    end

    context 'with token' do
      before { authorize_read! }

      it 'orders each status by its minimum reaction id, not its latest reaction id' do
        status_a = Fabricate(:status, account: user.account)
        status_b = Fabricate(:status, account: user.account)
        status_c = Fabricate(:status, account: user.account)
        insert_reaction(id: 100, status: status_a, name: '👍')
        insert_reaction(id: 300, status: status_a, name: '❤️')
        insert_reaction(id: 200, status: status_b)
        insert_reaction(id: 400, status: status_c)
        insert_reaction(id: 150, status: status_c, account: Fabricate(:account), name: '🎉')

        get :index

        expect(response).to have_http_status(200)
        expect(status_ids).to eq [status_c.id.to_s, status_b.id.to_s, status_a.id.to_s]
      end

      it 'returns only the first page of representative ids' do
        statuses = Array.new(4) { Fabricate(:status, account: user.account) }
        insert_reaction(id: 110, status: statuses[0])
        insert_reaction(id: 120, status: statuses[1])
        insert_reaction(id: 130, status: statuses[2])
        insert_reaction(id: 140, status: statuses[3])

        get :index, params: { limit: 2 }

        expect(status_ids).to eq [statuses[3].id.to_s, statuses[2].id.to_s]
        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&max_id=130'
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&min_id=140'
      end

      it 'paginates older representative ids with max_id' do
        statuses = Array.new(4) { Fabricate(:status, account: user.account) }
        [110, 120, 130, 140].each_with_index { |id, index| insert_reaction(id: id, status: statuses[index]) }

        get :index, params: { limit: 2, max_id: 140 }

        expect(status_ids).to eq [statuses[2].id.to_s, statuses[1].id.to_s]
        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&max_id=120'
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&min_id=130'
      end

      it 'returns the largest representative ids above since_id' do
        statuses = Array.new(4) { Fabricate(:status, account: user.account) }
        [110, 120, 130, 140].each_with_index { |id, index| insert_reaction(id: id, status: statuses[index]) }

        get :index, params: { limit: 2, since_id: 110 }

        expect(status_ids).to eq [statuses[3].id.to_s, statuses[2].id.to_s]
      end

      it 'applies since_id and max_id together on the descending scan' do
        statuses = Array.new(5) { Fabricate(:status, account: user.account) }
        [110, 120, 130, 140, 150].each_with_index { |id, index| insert_reaction(id: id, status: statuses[index]) }

        statements = capture_statements { get :index, params: { limit: 2, since_id: 110, max_id: 150 } }
        candidate = statements.find { |statement| statement[:sql].include?('NOT EXISTS') && statement[:sql].include?('earlier.id') }

        expect(status_ids).to eq [statuses[3].id.to_s, statuses[2].id.to_s]
        expect(candidate[:sql]).to match(/"emoji_reactions"\."id" > 110\b/)
        expect(candidate[:sql]).to match(/"emoji_reactions"\."id" < 150\b/)
        expect(candidate[:sql]).to match(/ORDER BY "emoji_reactions"\."id" DESC/)
      end

      it 'pages by representative ids when later reactions sit between them' do
        oldest = Fabricate(:status, account: user.account)
        middle = Fabricate(:status, account: user.account)
        newest = Fabricate(:status, account: user.account)
        insert_reaction(id: 100, status: oldest)
        insert_reaction(id: 200, status: middle)
        insert_reaction(id: 500, status: newest)
        (210..490).step(10).each_with_index do |reaction_id, index|
          insert_reaction(id: reaction_id, status: middle, name: "extra#{index}")
        end

        get :index, params: { limit: 2 }

        expect(status_ids).to eq [newest.id.to_s, middle.id.to_s]
        expect(status_ids.uniq).to eq status_ids
        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&max_id=200'
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&min_id=500'

        controller.remove_instance_variable(:@_results)
        get :index, params: { limit: 2, max_id: 200 }

        expect(status_ids).to eq [oldest.id.to_s]
      end

      it 'returns the representative ids immediately above min_id in descending order' do
        statuses = Array.new(5) { Fabricate(:status, account: user.account) }
        [110, 120, 130, 140, 150].each_with_index { |id, index| insert_reaction(id: id, status: statuses[index]) }

        get :index, params: { limit: 2, min_id: 110 }

        expect(status_ids).to eq [statuses[2].id.to_s, statuses[1].id.to_s]
        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&max_id=120'
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&min_id=130'
      end

      it 'keeps the max_id bound when paging forward from min_id' do
        statuses = Array.new(5) { Fabricate(:status, account: user.account) }
        [110, 120, 130, 140, 150].each_with_index { |id, index| insert_reaction(id: id, status: statuses[index]) }

        get :index, params: { limit: 2, min_id: 110, max_id: 150 }

        expect(status_ids).to eq [statuses[2].id.to_s, statuses[1].id.to_s]
      end

      it 'selects representative ids with a bounded scan before loading statuses' do
        statuses = Array.new(4) { Fabricate(:status, account: user.account) }
        [210, 220, 230, 240].each_with_index { |id, index| insert_reaction(id: id, status: statuses[index]) }

        queries = capture_sql { get :index, params: { limit: 2 } }
        candidates = candidate_queries(queries)
        lookups = reaction_lookup_queries(queries)

        expect(candidates.size).to eq 1
        expect(candidates.first).to match(/NOT EXISTS/)
        expect(candidates.first).to match(/ORDER BY "emoji_reactions"\."id" DESC/)
        expect(candidates.first).to match(/LIMIT/)
        expect(candidates.first).not_to match(/GROUP BY/i)
        expect(candidates.first).not_to match(/MIN\(/)
        expect(candidates.first).not_to match(/JOIN/i)
        expect(candidates.first).not_to match(/"statuses"/)
        expect(candidates.first).not_to match(/IN \(SELECT/i)
        expect(lookups.size).to eq 1
        expect(in_list_size(lookups.first)).to eq 4
        expect(in_list_size(lookups.first)).to be <= Api::V1::EmojiReactionsController::REPRESENTATIVE_BATCH_SIZE
        expect(lookups.first).not_to match(/GROUP BY/i)
        expect(lookups.first).to match(/INNER JOIN "statuses" ON "statuses"\."deleted_at" IS NULL AND "statuses"\."id" = "emoji_reactions"\."status_id"/)
        expect(lookups.first).not_to match(/expired_at IS NULL/)
        expect(queries.grep(/IN \(SELECT/i)).to be_empty
      end

      it 'does not let a discarded status consume the representative limit' do
        status_a = Fabricate(:status, account: user.account)
        status_b = Fabricate(:status, account: user.account)
        status_c = Fabricate(:status, account: user.account)
        insert_reaction(id: 100, status: status_a)
        insert_reaction(id: 200, status: status_b)
        insert_reaction(id: 300, status: status_c)
        status_c.discard

        get :index, params: { limit: 2 }

        expect(EmojiReaction.where(status_id: status_c.id, id: 300)).to exist
        expect(status_ids).to eq [status_b.id.to_s, status_a.id.to_s]
        expect(response.headers['Link'].find_link(%w(rel next)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&max_id=100'
        expect(response.headers['Link'].find_link(%w(rel prev)).href).to eq 'http://test.host/api/v1/emoji_reactions?limit=2&min_id=200'
      end

      it 'filters emojis on the existing representative query' do
        thumb = Fabricate(:status, account: user.account)
        heart = Fabricate(:status, account: user.account)
        insert_reaction(id: 310, status: thumb, name: '👍')
        insert_reaction(id: 320, status: heart, name: '❤️')

        queries = capture_sql { get :index, params: { emojis: ['👍'] } }

        expect(status_ids).to eq [thumb.id.to_s]
        expect(candidate_queries(queries)).to be_empty
        expect(queries.join).to match(/IN \(SELECT/i)
      end

      it 'keeps only_media on the existing filtered query' do
        with_media = Fabricate(:status, account: user.account)
        without_media = Fabricate(:status, account: user.account)
        Fabricate(:media_attachment, account: user.account, status: with_media)
        insert_reaction(id: 410, status: with_media)
        insert_reaction(id: 420, status: without_media)

        queries = capture_sql { get :index, params: { only_media: true } }

        expect(status_ids).to eq [with_media.id.to_s]
        expect(candidate_queries(queries)).to be_empty
        expect(queries.join).to match(/IN \(SELECT/i)
      end

      it 'keeps without_media on the existing filtered query' do
        with_media = Fabricate(:status, account: user.account)
        plain = Fabricate(:status, account: user.account)
        Fabricate(:media_attachment, account: user.account, status: with_media)
        insert_reaction(id: 510, status: with_media)
        insert_reaction(id: 520, status: plain)

        queries = capture_sql { get :index, params: { without_media: true } }

        expect(status_ids).to eq [plain.id.to_s]
        expect(candidate_queries(queries)).to be_empty
        expect(queries.join).to match(/IN \(SELECT/i)
      end

      it 'continues past discarded representatives in later batches' do
        allow(controller).to receive(:representative_batch_size).and_return(2)
        discarded = Array.new(2) { Fabricate(:status, account: user.account) }
        live = Array.new(3) { Fabricate(:status, account: user.account) }
        insert_reaction(id: 500, status: discarded[0])
        insert_reaction(id: 400, status: discarded[1])
        insert_reaction(id: 300, status: live[0])
        insert_reaction(id: 200, status: live[1])
        insert_reaction(id: 100, status: live[2])
        discarded.each(&:discard)

        statements = capture_statements { get :index, params: { limit: 2 } }
        queries = statements.map { |statement| statement[:sql] }
        candidates = statements.select { |statement| statement[:sql].include?('NOT EXISTS') && statement[:sql].include?('earlier.id') }

        expect(status_ids).to eq [live[0].id.to_s, live[1].id.to_s]
        expect(candidates.size).to eq 2
        expect(candidates.map { |statement| statement[:sql] }).to all(match(/ORDER BY "emoji_reactions"\."id" DESC/))
        expect(candidates.first[:sql]).not_to match(/"emoji_reactions"\."id" </)
        expect(candidates.second[:sql]).to match(/"emoji_reactions"\."id" < 400\b/)
        expect(candidates.second[:sql]).not_to match(/"emoji_reactions"\."id" < 500\b/)
        expect(candidates.second[:sql]).not_to match(/"emoji_reactions"\."id" <= 400\b/)
        expect(reaction_lookup_queries(queries).map { |sql| in_list_size(sql) }).to eq [2, 2]
      end

      it 'continues past discarded representatives when scanning forward from min_id' do
        allow(controller).to receive(:representative_batch_size).and_return(2)
        discarded = Array.new(2) { Fabricate(:status, account: user.account) }
        live = Array.new(3) { Fabricate(:status, account: user.account) }
        insert_reaction(id: 100, status: discarded[0])
        insert_reaction(id: 200, status: discarded[1])
        insert_reaction(id: 300, status: live[0])
        insert_reaction(id: 400, status: live[1])
        insert_reaction(id: 500, status: live[2])
        discarded.each(&:discard)

        statements = capture_statements { get :index, params: { limit: 2, min_id: 50 } }
        queries = statements.map { |statement| statement[:sql] }
        candidates = statements.select { |statement| statement[:sql].include?('NOT EXISTS') && statement[:sql].include?('earlier.id') }

        expect(status_ids).to eq [live[1].id.to_s, live[0].id.to_s]
        expect(candidates.size).to eq 2
        expect(candidates.map { |statement| statement[:sql] }).to all(match(/ORDER BY "emoji_reactions"\."id" ASC/))
        expect(candidates.second[:sql]).to match(/"emoji_reactions"\."id" > 200\b/)
        expect(candidates.second[:sql]).not_to match(/"emoji_reactions"\."id" > 100\b/)
        expect(candidates.second[:sql]).not_to match(/"emoji_reactions"\."id" >= 200\b/)
        expect(reaction_lookup_queries(queries).map { |sql| in_list_size(sql) }).to eq [2, 2]
      end

      it 'keeps an expired status in the unfiltered page' do
        expired = Fabricate(:status, account: user.account)
        live = Fabricate(:status, account: user.account)
        expired.update_column(:expired_at, 1.hour.ago)
        insert_reaction(id: 710, status: expired)
        insert_reaction(id: 720, status: live)

        queries = capture_sql { get :index }

        expect(status_ids).to eq [live.id.to_s, expired.id.to_s]
        expect(reaction_lookup_queries(queries).join).to match(/INNER JOIN "statuses" ON "statuses"\."deleted_at" IS NULL/)
        expect(reaction_lookup_queries(queries).join).not_to match(/expired_at IS NULL/)
      end

      it 'uses the same status order for compact responses' do
        older = Fabricate(:status, account: user.account)
        newer = Fabricate(:status, account: user.account)
        insert_reaction(id: 610, status: older)
        insert_reaction(id: 620, status: newer)

        get :index, params: { limit: 2 }
        paged_ids = status_ids
        next_id = link_param('next', 'max_id')
        previous_id = link_param('prev', 'min_id')

        get :index, params: { limit: 2, compact: true }

        expect(body_as_json[:statuses].map { |status| status[:id] }).to eq paged_ids
        expect(paged_ids).to eq [newer.id.to_s, older.id.to_s]
        expect(link_param('next', 'max_id')).to eq next_id
        expect(link_param('prev', 'min_id')).to eq previous_id
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
