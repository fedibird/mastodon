# frozen_string_literal: true

require 'rails_helper'

describe StatusesSearchService, type: :service do
  subject { described_class.new }

  let(:searcher) { Fabricate(:account, searchability: :public) }
  let(:mutual_local) { Fabricate(:account, searchability: :public) }
  let(:one_way) { Fabricate(:account, searchability: :public) }
  let!(:mutual_status) { Fabricate(:status, account: mutual_local, text: 'mutual cat', visibility: :public, searchability: :public) }
  let!(:blocked_status) { Fabricate(:status, account: mutual_blocked, text: 'blocked cat', visibility: :public, searchability: :public) }
  let(:mutual_blocked) { Fabricate(:account, searchability: :public) }

  before do
    searcher.follow!(mutual_local)
    mutual_local.follow!(searcher)
    searcher.follow!(one_way)
    searcher.follow!(mutual_blocked)
    mutual_blocked.follow!(searcher)
    searcher.block!(mutual_blocked)
  end

  def capture_search(hits: [])
    captured = []
    allow(Chewy.client).to receive(:search) do |request|
      captured << request
      # Hits stand in for documents the keyword would match. A required match_none
      # drops them, so an empty result is a consequence of the query rather than the stub.
      visible = required_match_none?(request) ? [] : hits
      { 'hits' => { 'total' => { 'value' => visible.size }, 'hits' => visible } }
    end
    captured
  end

  def required_match_none?(request)
    clauses = []
    walk = lambda do |node|
      case node
      when Array
        node.each { |child| walk.call(child) }
      when Hash
        bool = node[:bool] || node['bool']
        if bool.is_a?(Hash)
          Array(bool[:must] || bool['must']).each do |clause|
            clauses << clause
            walk.call(clause)
          end
        else
          node.each_value { |child| walk.call(child) }
        end
      end
    end
    walk.call(request)
    clauses.any? { |clause| clause.is_a?(Hash) && (clause.key?(:match_none) || clause.key?('match_none')) }
  end

  def symbolize(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child), result| result[key.to_sym] = symbolize(child) }
    when Array
      value.map { |child| symbolize(child) }
    else
      value
    end
  end

  def included_account_ids(request)
    included = []
    walk = lambda do |node, must_not|
      case node
      when Array
        node.each { |child| walk.call(child, must_not) }
      when Hash
        bool = node[:bool]
        if bool
          %i(must should filter).each { |key| walk.call(bool[key], must_not) }
          walk.call(bool[:must_not], true)
          next
        end

        terms = node[:terms] || node[:term]
        values = terms && (terms[:account_id])
        included.concat(Array(values)) if values && !must_not
        node.each_value { |child| walk.call(child, must_not) }
      end
    end
    walk.call(symbolize(request), false)
    included
  end

  it 'pages an in:mutual query without widening it to one-way follows' do
    captured = capture_search(hits: [{ '_source' => { 'id' => mutual_status.id } }, { '_source' => { 'id' => blocked_status.id } }])

    results = subject.call('cat in:mutual', searcher, limit: 2, offset: 3)

    body = symbolize(captured.first).fetch(:body)
    expect(body[:size]).to eq(2)
    expect(body[:from]).to eq(3)
    expect(included_account_ids(captured.first)).to include(mutual_local.id, mutual_blocked.id)
    expect(included_account_ids(captured.first)).not_to include(one_way.id)
    expect(JSON.generate(body)).to include('public', 'unlisted', 'private')
    expect(JSON.generate(body)).not_to include('"searchability":"mutual"')
    expect(results).to eq([mutual_status])
  end

  it 'returns no rows for an account with no mutual follows' do
    lonely = Fabricate(:account, searchability: :public)
    stranger_status = Fabricate(:status, text: 'stranger cat', visibility: :public, searchability: :public)
    captured = capture_search(hits: [{ '_source' => { 'id' => stranger_status.id } }])

    results = subject.call('cat in:mutual', lonely, limit: 20, offset: 0)

    expect(required_match_none?(captured.first)).to be true
    expect(results).to eq([])
  end

  it 'returns no rows for in:follow when the searcher follows nobody' do
    lonely = Fabricate(:account, searchability: :public)
    stranger_status = Fabricate(:status, text: 'stranger cat', visibility: :public, searchability: :public)
    captured = capture_search(hits: [{ '_source' => { 'id' => stranger_status.id } }])

    results = subject.call('cat in:follow', lonely, limit: 20, offset: 0)

    expect(required_match_none?(captured.first)).to be true
    expect(results).to eq([])
  end

  it 'keeps in:follow limited to followed accounts across pages' do
    captured = capture_search(hits: [])

    subject.call('cat in:follow', searcher, limit: 5, offset: 10)

    body = symbolize(captured.first).fetch(:body)
    expect(body[:size]).to eq(5)
    expect(body[:from]).to eq(10)
    expect(included_account_ids(captured.first)).to include(mutual_local.id, one_way.id, mutual_blocked.id)
  end
end
