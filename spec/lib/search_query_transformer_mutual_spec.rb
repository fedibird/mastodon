# frozen_string_literal: true

require 'rails_helper'

describe SearchQueryTransformer do
  let(:searcher) { Fabricate(:account, username: 'searcher', searchability: :public) }
  let(:mutual_local) { Fabricate(:account, username: 'bee', searchability: :public) }
  let(:one_way) { Fabricate(:account, username: 'cee', searchability: :public) }
  let(:follows_searcher) { Fabricate(:account, username: 'dee', searchability: :public) }
  let(:stranger) { Fabricate(:account, username: 'eee', searchability: :public) }
  let(:mutual_remote) { Fabricate(:account, username: 'rem', domain: 'remote.example', searchability: :public) }
  let(:pending_target) { Fabricate(:account, username: 'pending', searchability: :public) }
  let(:requested_back) { Fabricate(:account, username: 'requested', searchability: :public) }

  def build_query(text, searchability: 'private')
    described_class.new.apply(
      SearchQueryParser.new.parse(text),
      current_account: searcher,
      searchability: searchability
    )
  end

  def collect_terms(node, field, must_not: false, included: [], excluded: [])
    case node
    when Array
      node.each { |child| collect_terms(child, field, must_not: must_not, included: included, excluded: excluded) }
    when Hash
      bool = node[:bool] || node['bool']
      if bool.is_a?(Hash)
        %i(must should filter).each do |key|
          collect_terms(bool[key] || bool[key.to_s], field, must_not: must_not, included: included, excluded: excluded)
        end
        collect_terms(bool[:must_not] || bool['must_not'], field, must_not: true, included: included, excluded: excluded)
      else
        terms = node[:terms] || node['terms'] || node[:term] || node['term']
        if terms.is_a?(Hash)
          values = terms[field] || terms[field.to_s]
          (must_not ? excluded : included).concat(Array(values)) if values
        else
          node.each_value { |child| collect_terms(child, field, must_not: must_not, included: included, excluded: excluded) }
        end
      end
    end

    [included, excluded]
  end

  def account_ids_for(query)
    included, = collect_terms(query.request.render, :account_id)
    included
  end

  describe 'in:mutual' do
    before do
      searcher.follow!(mutual_local)
      mutual_local.follow!(searcher)
      searcher.follow!(one_way)
      follows_searcher.follow!(searcher)
      searcher.follow!(mutual_remote)
      mutual_remote.follow!(searcher)
      searcher.follow!(pending_target)
      pending_target.request_follow!(searcher)
      searcher.request_follow!(requested_back)
      requested_back.follow!(searcher)
    end

    it 'keeps mutual as a follow-graph filter distinct from status searchability' do
      expect(described_class::SUPPORTED_SEARCHABLITY_FILTER).to include('mutual')
      expect(described_class::SUPPORTED_PROPERTIES).not_to include('mutual')
      expect(Status.selectable_searchabilities).not_to include('mutual')
      expect { build_query('cat is:mutual') }.to raise_error(RuntimeError, /No support property/)
    end

    it 'limits authors to searchable accounts with a follow in both directions' do
      query = build_query('cat in:mutual')

      expect(query.mutual_account_ids).to contain_exactly(mutual_local.id, mutual_remote.id)
      expect(query.following_account_ids).to contain_exactly(mutual_local.id, one_way.id, mutual_remote.id, pending_target.id)

      included = account_ids_for(query)
      searchabilities, = collect_terms(query.request.render, :searchability)

      expect(included).to include(mutual_local.id, mutual_remote.id)
      expect(included).not_to include(one_way.id, follows_searcher.id, stranger.id, pending_target.id, requested_back.id, searcher.id)
      expect(searchabilities).to contain_exactly('public', 'unlisted', 'private')
    end

    it 'selects mutual authors with one EXISTS query and ignores follow requests' do
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        next if payload[:name] == 'SCHEMA' || sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

        queries << sql
      end

      query = build_query('cat in:mutual')
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { query.mutual_account_ids }

      follow_queries = queries.grep(/FROM "follows"/)
      expect(follow_queries.size).to eq(1)
      expect(follow_queries.first).to include('reverse_follows')
      expect(follow_queries.first).to include('EXISTS')
      expect(queries.join(' ')).not_to include('follow_requests')
    end

    it 'drops an author as soon as either follow is removed and restores them when it is recreated' do
      expect(build_query('cat in:mutual').mutual_account_ids).to include(mutual_local.id)

      searcher.unfollow!(mutual_local)
      expect(build_query('cat in:mutual').mutual_account_ids).not_to include(mutual_local.id)
      expect(build_query('cat in:follow').following_account_ids).not_to include(mutual_local.id)

      mutual_local.unfollow!(searcher)
      searcher.follow!(mutual_local)
      expect(build_query('cat in:mutual').mutual_account_ids).not_to include(mutual_local.id)
      expect(build_query('cat in:follow').following_account_ids).to include(mutual_local.id)

      mutual_local.follow!(searcher)
      expect(build_query('cat in:mutual').mutual_account_ids).to include(mutual_local.id)
    end

    it 'includes a mutual account through a searchable status when the account itself is not searchable' do
      qualified = Fabricate(:account, searchability: :direct)
      searcher.follow!(qualified)
      qualified.follow!(searcher)
      Fabricate(:status, account: qualified, text: 'visible cat', visibility: :public, searchability: :public)

      hidden = Fabricate(:account, searchability: :mutual)
      searcher.follow!(hidden)
      hidden.follow!(searcher)
      Fabricate(:status, account: hidden, text: 'hidden cat', visibility: :mutual, searchability: :mutual)

      direct_only = Fabricate(:account, searchability: :direct)
      searcher.follow!(direct_only)
      direct_only.follow!(searcher)
      Fabricate(:status, account: direct_only, text: 'direct cat', visibility: :direct, searchability: :direct)

      reblogger = Fabricate(:account, searchability: :direct)
      searcher.follow!(reblogger)
      reblogger.follow!(searcher)
      original = Fabricate(:status, text: 'boosted cat', visibility: :public, searchability: :public)
      Fabricate(:status, account: reblogger, reblog: original)

      query = build_query('cat in:mutual')

      expect(query.mutual_account_ids).to include(qualified.id)
      expect(query.mutual_account_ids).not_to include(hidden.id, direct_only.id, reblogger.id)
      expect(query.following_account_ids).to include(qualified.id)
      expect(query.following_account_ids).not_to include(hidden.id, direct_only.id, reblogger.id)
    end

    it 'matches nothing when the searcher has no mutual follows' do
      lonely = Fabricate(:account, searchability: :public)
      query = described_class.new.apply(
        SearchQueryParser.new.parse('cat in:mutual'),
        current_account: lonely,
        searchability: 'all'
      )

      rendered = JSON.generate(query.request.render)

      expect(query.mutual_account_ids).to eq([])
      expect(rendered).to include('match_none')
      expect(rendered).to include('cat')
      expect(account_ids_for(query)).not_to include(mutual_local.id, one_way.id)
    end

    it 'still lets in:follow see one-way follows and leaves in:public and in:all unchanged' do
      follow_ids = account_ids_for(build_query('cat in:follow'))
      expect(follow_ids).to include(mutual_local.id, one_way.id, mutual_remote.id, pending_target.id)
      expect(follow_ids).not_to include(follows_searcher.id, stranger.id, requested_back.id)

      public_ids = account_ids_for(build_query('cat in:public'))
      expect(public_ids).not_to include(mutual_local.id, one_way.id)
      public_searchability, = collect_terms(build_query('cat in:public').request.render, :searchability)
      expect(public_searchability).to eq(['public'])

      all_ids = account_ids_for(build_query('cat in:all'))
      expect(all_ids).to include(one_way.id, mutual_local.id)
      expect(all_ids).not_to include(follows_searcher.id, stranger.id)
    end

    it 'combines the author filter with keyword, from, language, date, and order operators' do
      query = build_query('猫 from:bee lang:en since:2020-01-01 in:mutual order:asc')
      rendered = query.request.render
      json = JSON.generate(rendered)
      included = account_ids_for(query)

      expect(included).to include(mutual_local.id)
      expect(included).not_to include(one_way.id)
      expect(json).to include('text.en_stemmed')
      expect(json).to include('猫')
      expect(json).to include('2020-01-01')
      expect(rendered.dig(:body, :sort)).to eq([{ 'created_at' => 'asc' }])
    end

    it 'keeps mute and domain exclusions in front of the mutual author filter' do
      searcher.mute!(mutual_local)
      searcher.block_domain!('remote.example')

      _included, excluded_accounts = collect_terms(build_query('cat in:mutual').request.render, :account_id)
      _searchability, excluded_domains = collect_terms(build_query('cat in:mutual').request.render, :domain)

      expect(build_query('cat in:mutual').mutual_account_ids).to include(mutual_local.id, mutual_remote.id)
      expect(excluded_accounts).to include(mutual_local.id)
      expect(excluded_domains).to include('remote.example')
    end
  end
end
