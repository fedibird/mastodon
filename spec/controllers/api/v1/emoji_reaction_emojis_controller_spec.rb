# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe Api::V1::EmojiReactionEmojisController, type: :controller do
  render_views

  let(:user) { Fabricate(:user) }
  let(:now) { Time.utc(2026, 4, 1, 12, 0, 0) }

  def authorize!(scopes)
    allow(controller).to receive(:doorkeeper_token) do
      Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes)
    end
  end

  def insert_reaction(id:, status:, **options)
    created_at = options.fetch(:created_at, now)
    account = options.fetch(:account, user.account)
    row = {
      id: id,
      account_id: account.id,
      status_id: status.id,
      name: options.fetch(:name, '👍'),
      custom_emoji_id: options[:custom_emoji_id],
      created_at: created_at,
      updated_at: created_at,
    }
    EmojiReaction.insert_all!([row])
  end

  def catalog
    body_as_json
  end

  def capture_statements(&block)
    statements = []
    callback = lambda do |*_args, payload|
      casted = payload[:type_casted_binds]
      casted = casted.call if casted.respond_to?(:call)
      statements << { sql: payload[:sql].to_s, binds: Array(casted), name: payload[:name].to_s }
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    statements
  end

  def aggregate_statement(statements)
    statements.find { |statement| statement[:sql].include?('GROUP BY') && statement[:sql].include?('emoji_reactions') }
  end

  def custom_emoji_selects(statements)
    statements.select { |statement| statement[:name] != 'CACHE' && statement[:sql].match?(/FROM "custom_emojis"/) }
  end

  describe 'GET #index' do
    it 'routes the emoji catalog collection' do
      expect(get: '/api/v1/emoji_reactions/emojis').to route_to(
        controller: 'api/v1/emoji_reaction_emojis',
        action: 'index'
      )
    end

    context 'without a token' do
      it 'returns http unauthorized' do
        get :index

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'without a usable scope' do
      before { authorize!('') }

      it 'returns http forbidden' do
        get :index

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'with the read scope' do
      before { authorize!('read') }

      it 'returns only the current account catalog' do
        status = Fabricate(:status, account: user.account)
        insert_reaction(id: 100, status: status, name: '👍')
        insert_reaction(id: 200, status: Fabricate(:status), name: '🎉', account: Fabricate(:account))

        get :index

        expect(response).to have_http_status(200)
        expect(catalog.map { |item| item[:name] }).to eq ['👍']
        expect(catalog.first[:count]).to eq 1
      end
    end

    context 'with the read:favourites scope' do
      before { authorize!('read:favourites') }

      it 'returns an empty catalog when the account has no reactions' do
        get :index

        expect(response).to have_http_status(200)
        expect(catalog).to eq []
        expect(response.headers['Link']).to be_nil
      end

      it 'counts each unicode identity by the statuses it currently marks' do
        statuses = Array.new(3) { Fabricate(:status, account: user.account) }
        insert_reaction(id: 110, status: statuses[0], name: '👍', created_at: Time.utc(2026, 1, 1))
        insert_reaction(id: 120, status: statuses[1], name: '👍', created_at: Time.utc(2026, 1, 2))
        insert_reaction(id: 130, status: statuses[2], name: '🎉', created_at: Time.utc(2026, 1, 3))

        statements = capture_statements { get :index }
        thumbs = catalog.find { |item| item[:name] == '👍' }
        party = catalog.find { |item| item[:name] == '🎉' }

        expect(response).to have_http_status(200)
        expect(catalog.map { |item| item[:name] }).to eq ['👍', '🎉']
        expect(thumbs).to include(domain: nil, custom: false, count: 2, last_used_at: Time.utc(2026, 1, 2).iso8601(3))
        expect(thumbs[:count]).to be_a(Integer)
        expect(thumbs.keys).to contain_exactly(:name, :domain, :custom, :count, :last_used_at)
        expect(party).to include(domain: nil, custom: false, count: 1)
        expect(response.body).to include('"count":2')
        expect(response.body).not_to include('"count":"')
        expect(custom_emoji_selects(statements)).to be_empty
      end

      it 'counts each identity separately when one status has several reactions' do
        status = Fabricate(:status, account: user.account)
        insert_reaction(id: 210, status: status, name: '👍', created_at: Time.utc(2026, 1, 2))
        insert_reaction(id: 220, status: status, name: '🎉', created_at: Time.utc(2026, 1, 1))

        get :index

        expect(catalog.map { |item| [item[:name], item[:count]] }).to eq [['👍', 1], ['🎉', 1]]
      end

      it 'returns local custom emoji metadata and omits empty optional fields' do
        emoji = Fabricate(:custom_emoji, shortcode: 'great', domain: nil)
        insert_reaction(id: 310, status: Fabricate(:status, account: user.account), name: 'great', custom_emoji_id: emoji.id)

        get :index

        item = catalog.first
        expect(item).to include(name: 'great', domain: nil, custom: true, count: 1)
        expect(item[:url]).to start_with('http')
        expect(item[:static_url]).to start_with('http')
        expect(item.keys).not_to include(:category, :visible_in_picker)
      end

      it 'returns optional custom emoji metadata when it is present' do
        emoji = Fabricate(:custom_emoji, shortcode: 'great', domain: nil, alternate_name: 'すごい', ruby: 'グレート', aliases: ['nice'])
        emoji.update_columns(width: 128, height: 64, thumbhash: 'thumbhash-value')
        insert_reaction(id: 320, status: Fabricate(:status, account: user.account), name: 'great', custom_emoji_id: emoji.id)

        get :index

        expect(catalog.first).to include(
          name: 'great',
          domain: nil,
          custom: true,
          width: 128,
          height: 64,
          thumbhash: 'thumbhash-value',
          alternate_name: 'すごい',
          ruby: 'グレート',
          aliases: %w(すごい グレート nice)
        )
      end

      it 'returns a remote custom emoji separately from a local emoji with the same shortcode' do
        local_emoji = Fabricate(:custom_emoji, shortcode: 'great', domain: nil)
        remote_emoji = Fabricate(:custom_emoji, shortcode: 'great', domain: 'example.com')
        insert_reaction(id: 410, status: Fabricate(:status, account: user.account), name: 'great', custom_emoji_id: local_emoji.id, created_at: Time.utc(2026, 2, 1))
        insert_reaction(id: 420, status: Fabricate(:status, account: user.account), name: 'great', custom_emoji_id: remote_emoji.id, created_at: Time.utc(2026, 2, 2))

        get :index

        expect(catalog.map { |item| [item[:name], item[:domain], item[:custom], item[:count]] }).to eq [
          ['great', 'example.com', true, 1],
          ['great', nil, true, 1],
        ]
        expect(catalog.first[:url]).to start_with('http')
        expect(catalog.first[:static_url]).to start_with('http')
      end

      it 'returns one identity per domain when the shortcode is the same' do
        local_emoji = Fabricate(:custom_emoji, shortcode: 'great', domain: nil)
        com_emoji = Fabricate(:custom_emoji, shortcode: 'great', domain: 'example.com')
        net_emoji = Fabricate(:custom_emoji, shortcode: 'great', domain: 'example.net')
        used_at = Time.utc(2026, 3, 1, 0, 0, 0)
        [local_emoji, com_emoji, net_emoji].each_with_index do |emoji, index|
          insert_reaction(
            id: 500 + index,
            status: Fabricate(:status, account: user.account),
            name: 'great',
            custom_emoji_id: emoji.id,
            created_at: used_at
          )
        end

        get :index

        expected = [local_emoji, com_emoji, net_emoji].sort_by(&:id).map do |emoji|
          [emoji.shortcode, emoji.domain, true]
        end
        expect(catalog.map { |item| [item[:name], item[:domain], item[:custom]] }).to eq expected
      end

      it 'includes a custom emoji that is hidden from the normal picker' do
        emoji = Fabricate(:custom_emoji, shortcode: 'hidden', visible_in_picker: false)
        insert_reaction(id: 610, status: Fabricate(:status, account: user.account), name: 'hidden', custom_emoji_id: emoji.id)

        get :index

        expect(emoji.visible_in_picker).to be false
        expect(catalog.map { |item| [item[:name], item[:domain], item[:custom]] }).to eq [['hidden', nil, true]]
        expect(catalog.first.keys).not_to include(:visible_in_picker, :category)
      end

      it 'orders identities by count before recency' do
        oldest = Time.utc(2026, 1, 1, 0, 0, 0)
        middle = Time.utc(2026, 3, 1, 0, 0, 0)
        newest = Time.utc(2026, 6, 1, 0, 0, 0)
        thumbs = Array.new(3) { Fabricate(:status, account: user.account) }
        parties = Array.new(2) { Fabricate(:status, account: user.account) }
        heart = Fabricate(:status, account: user.account)
        insert_reaction(id: 710, status: thumbs[0], name: '👍', created_at: oldest)
        insert_reaction(id: 711, status: thumbs[1], name: '👍', created_at: oldest)
        insert_reaction(id: 712, status: thumbs[2], name: '👍', created_at: oldest)
        insert_reaction(id: 720, status: parties[0], name: '🎉', created_at: middle)
        insert_reaction(id: 721, status: parties[1], name: '🎉', created_at: middle)
        insert_reaction(id: 730, status: heart, name: '❤️', created_at: newest)

        get :index

        expect(catalog.map { |item| [item[:name], item[:count]] }).to eq [['👍', 3], ['🎉', 2], ['❤️', 1]]
      end

      it 'breaks equal counts by the latest remaining reaction' do
        earlier = Time.utc(2026, 1, 1, 0, 0, 0)
        middle = Time.utc(2026, 2, 1, 0, 0, 0)
        later = Time.utc(2026, 3, 1, 8, 30, 0)
        insert_reaction(id: 810, status: Fabricate(:status, account: user.account), name: '👍', created_at: earlier)
        insert_reaction(id: 811, status: Fabricate(:status, account: user.account), name: '👍', created_at: middle)
        insert_reaction(id: 820, status: Fabricate(:status, account: user.account), name: '🎉', created_at: earlier)
        insert_reaction(id: 821, status: Fabricate(:status, account: user.account), name: '🎉', created_at: later)

        get :index

        expect(catalog.map { |item| item[:name] }).to eq ['🎉', '👍']
        expect(catalog.map { |item| item[:count] }).to eq [2, 2]
        expect(catalog.map { |item| item[:last_used_at] }).to eq [later.iso8601(3), middle.iso8601(3)]
      end

      it 'breaks remaining ties by name' do
        used_at = Time.utc(2026, 5, 1, 0, 0, 0)
        insert_reaction(id: 910, status: Fabricate(:status, account: user.account), name: 'beta', created_at: used_at)
        insert_reaction(id: 911, status: Fabricate(:status, account: user.account), name: 'alpha', created_at: used_at)

        get :index

        expect(catalog.map { |item| item[:name] }).to eq %w(alpha beta)
        expect(catalog.map { |item| item[:custom] }).to eq [false, false]
      end

      it 'leaves out an identity that only remains on a discarded status' do
        live = Fabricate(:status, account: user.account)
        discarded = Fabricate(:status, account: user.account)
        insert_reaction(id: 1010, status: live, name: '👍')
        insert_reaction(id: 1020, status: discarded, name: '👍')
        insert_reaction(id: 1030, status: discarded, name: '🎉')
        discarded.discard

        statements = capture_statements { get :index }
        aggregate = aggregate_statement(statements)

        expect(catalog.map { |item| [item[:name], item[:count]] }).to eq [['👍', 1]]
        expect(aggregate[:sql]).to include('"statuses"."deleted_at" IS NULL')
        expect(aggregate[:sql]).not_to match(/expired_at IS NULL/)
      end

      it 'keeps reactions on expired statuses' do
        expired = Fabricate(:status, account: user.account)
        live = Fabricate(:status, account: user.account)
        expired.update_column(:expired_at, 1.hour.ago)
        insert_reaction(id: 1110, status: expired, name: '❤️', created_at: Time.utc(2026, 1, 2))
        insert_reaction(id: 1120, status: live, name: '👍', created_at: Time.utc(2026, 1, 1))

        statements = capture_statements { get :index }
        aggregate = aggregate_statement(statements)
        grouped_at = aggregate[:sql].index('GROUP BY')

        expect(catalog.map { |item| [item[:name], item[:count]] }).to eq [['❤️', 1], ['👍', 1]]
        expect(aggregate[:sql]).to include('INNER JOIN "statuses" ON "statuses"."deleted_at" IS NULL AND "statuses"."id" = "emoji_reactions"."status_id"')
        expect(aggregate[:sql]).not_to match(/expired_at IS NULL/)
        expect(aggregate[:sql]).to match(/"emoji_reactions"\."account_id" =/)
        expect(aggregate[:binds]).to include(user.account.id)
        expect(aggregate[:sql].index('WHERE')).to be < grouped_at
        expect(aggregate[:sql][0...grouped_at]).to include('account_id')
        expect(aggregate[:sql]).to match(/GROUP BY "emoji_reactions"\."name", "emoji_reactions"\."custom_emoji_id"/)
        expect(aggregate[:sql]).to include(Api::V1::EmojiReactionEmojisController::AGGREGATE_ORDER_SQL)
        expect(aggregate[:sql]).not_to match(/FROM\s+\(\s*SELECT/i)
        expect(aggregate[:sql]).not_to include('custom_emojis')
      end

      it 'loads custom emoji metadata with one query' do
        emojis = Array.new(4) { |index| Fabricate(:custom_emoji, shortcode: "emoji#{index}") }
        emojis.each_with_index do |emoji, index|
          insert_reaction(
            id: 1200 + index,
            status: Fabricate(:status, account: user.account),
            name: emoji.shortcode,
            custom_emoji_id: emoji.id,
            created_at: Time.utc(2026, 1, index + 1)
          )
        end

        statements = capture_statements { get :index }
        selects = custom_emoji_selects(statements)
        aggregate = aggregate_statement(statements)

        expect(catalog.map { |item| item[:name] }).to eq emojis.reverse.map(&:shortcode)
        expect(selects.size).to eq 1
        expect(selects.first[:sql]).to match(/"custom_emojis"\."id" IN \(/)
        expect(aggregate[:sql]).to match(/"emoji_reactions"\."account_id" =/)
        expect(aggregate[:binds]).to include(user.account.id)
        expect(aggregate[:sql]).not_to include('custom_emojis')
      end

      it 'returns every current identity without pagination' do
        3.times do |index|
          insert_reaction(
            id: 1300 + index,
            status: Fabricate(:status, account: user.account),
            name: "emoji#{index}",
            created_at: Time.utc(2026, 1, index + 1)
          )
        end

        get :index, params: { limit: 1 }

        expect(catalog.size).to eq 3
        expect(response.headers['Link']).to be_nil
      end

      it 'does not mix in another account reactions' do
        insert_reaction(id: 1410, status: Fabricate(:status, account: user.account), name: '🎉')
        insert_reaction(id: 1420, status: Fabricate(:status), name: '👍', account: Fabricate(:account))
        insert_reaction(id: 1430, status: Fabricate(:status), name: '👍', account: Fabricate(:account))

        get :index

        expect(catalog.map { |item| [item[:name], item[:count]] }).to eq [['🎉', 1]]
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
