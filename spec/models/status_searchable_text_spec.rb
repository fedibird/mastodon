# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Status, '#searchable_text', type: :model do # rubocop:disable Metrics/BlockLength
  let(:local_account) { Fabricate(:account, domain: nil, username: 'alice') }

  it 'keeps ordinary body text' do
    status = Fabricate(:status, account: local_account, text: 'hello foo')
    expect(status.searchable_text).to include('hello foo')
  end

  it 'includes content warning text' do
    status = Fabricate(:status, account: local_account, text: 'body', spoiler_text: 'spoilerword')
    expect(status.searchable_text).to include('spoilerword')
  end

  it 'strips ordinary URLs from local posts' do
    status = Fabricate(:status, account: local_account, text: "URL CHECK\nhttps://example.com/filter-url-test")

    expect(status.searchable_text).to include('URL CHECK')
    expect(status.searchable_text).not_to include('example.com')
    expect(status.searchable_text).not_to include('filter-url-test')
  end

  it 'keeps local mentions and hashtags after URL stripping' do
    status = Fabricate(:status, account: local_account, text: 'hello @alice #test https://example.com/x')

    expect(status.searchable_text).to include('@alice')
    expect(status.searchable_text).to include('#test')
    expect(status.searchable_text).not_to include('example.com')
  end

  it 'strips ordinary remote link URLs while keeping mention and hashtag text' do
    remote_account = Fabricate(:account, domain: 'remote.test', username: 'bob', url: 'https://remote.test/@bob')
    mentioned = Fabricate(:account, domain: 'remote.test', username: 'carol', url: 'https://remote.test/@carol')
    html = <<~HTML
      <p>hello <a href="https://remote.test/@carol" class="u-url mention">@carol</a> <a rel="tag" href="https://remote.test/tags/tag">#tag</a> <a href="https://example.com/filter-url-test">https://example.com/filter-url-test</a></p>
    HTML
    status = Fabricate(:status, account: remote_account, text: html)
    Fabricate(:mention, status: status, account: mentioned)

    expect(status.searchable_text).to include('hello')
    expect(status.searchable_text).to include('@carol')
    expect(status.searchable_text).to include('#tag')
    expect(status.searchable_text).not_to include('example.com')
    expect(status.searchable_text).not_to include('filter-url-test')
  end

  it 'uses proper searchable_text for reblogs' do
    original = Fabricate(:status, account: local_account, text: 'innerword https://example.com/filter-url-test')
    reblog = Fabricate(:status, account: local_account, reblog: original)

    expect(reblog.proper.searchable_text).to eq original.searchable_text
    expect(reblog.proper.searchable_text).to include('innerword')
    expect(reblog.proper.searchable_text).not_to include('example.com')
  end

  it 'still strips ordinary URLs from searchable_text while CustomFilter matches them via filterable_text' do
    viewer = Fabricate(:account)
    filter = Fabricate(:custom_filter, account: viewer, phrase: 'urls', context: %w(home notifications public thread account))
    Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: 'example.com')
    status = Fabricate(:status, account: local_account, text: "URL CHECK\nhttps://example.com/filter-url-test")

    expect(status.searchable_text).not_to include('example.com')
    results = CustomFilter.apply_cached_filters(CustomFilter.cached_filters_for(viewer.id), status)
    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include('example.com')
  end

  it 'matches a body keyword via CustomFilter' do
    viewer = Fabricate(:account)
    filter = Fabricate(:custom_filter, account: viewer, phrase: 'foo', context: %w(home notifications public thread account))
    Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: 'foo')
    status = Fabricate(:status, account: local_account, text: 'hello foo')

    results = CustomFilter.apply_cached_filters(CustomFilter.cached_filters_for(viewer.id), status)
    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include('foo')
  end
end
