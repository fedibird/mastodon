# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFilter, type: :model do # rubocop:disable Metrics/BlockLength
  def apply_filters(account, status)
    described_class.apply_cached_filters(described_class.cached_filters_for(account.id), status)
  end

  def keyword_filter_for(account, keyword)
    filter = Fabricate(:custom_filter, account: account, phrase: keyword, context: %w(home notifications public thread account))
    Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: keyword)
    filter
  end

  let(:viewer) { Fabricate(:account) }
  let(:author) { Fabricate(:account, domain: nil, username: 'alice') }

  it 'does not match an ordinary body URL' do
    keyword_filter_for(viewer, 'example.com')
    status = Fabricate(:status, account: author, text: 'hello https://example.com/article')

    expect(apply_filters(viewer, status)).to eq([])
  end

  it 'matches a referenced status public URL' do
    referenced = Fabricate(:status, account: author, text: 'original')
    referencing = Fabricate(:status, account: author, text: 'see this')
    Fabricate(:status_reference, status: referencing, target_status: referenced)
    keyword_filter_for(viewer, ActivityPub::TagManager.instance.url_for(referenced))

    results = apply_filters(viewer, referencing)

    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include(ActivityPub::TagManager.instance.url_for(referenced))
  end

  it 'matches a referenced remote status ActivityPub URI' do
    remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
    referenced = Fabricate(
      :status,
      account: remote,
      text: 'remote original',
      uri: 'https://example.social/users/bob/statuses/123',
      url: 'https://example.social/@bob/123'
    )
    referencing = Fabricate(:status, account: author, text: 'see remote')
    Fabricate(:status_reference, status: referencing, target_status: referenced)
    keyword_filter_for(viewer, referenced.uri)

    results = apply_filters(viewer, referencing)

    expect(ActivityPub::TagManager.instance.url_for(referenced)).to eq referenced.url
    expect(ActivityPub::TagManager.instance.uri_for(referenced)).to eq referenced.uri
    expect(referenced.url).not_to eq referenced.uri
    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include(referenced.uri)
  end

  it 'matches a quoted status URL and records the quote as a reference' do
    quoted = Fabricate(:status, account: author, text: 'quoted original')
    allow_any_instance_of(PostStatusService).to receive(:postprocess_status!)
    quoting = PostStatusService.new.call(author, text: 'quoting this', quote_id: quoted.id)
    quoted_url = ActivityPub::TagManager.instance.url_for(quoted)
    keyword_filter_for(viewer, quoted_url)

    expect(quoting.quote).to eq quoted
    expect(quoting.references).to include(quoted)

    results = apply_filters(viewer, quoting)

    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include(quoted_url)
  end

  it 'still matches ordinary body keywords' do
    keyword_filter_for(viewer, 'foobar')
    status = Fabricate(:status, account: author, text: 'hello foobar')

    results = apply_filters(viewer, status)

    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include('foobar')
  end

  it 'still matches content warning text' do
    keyword_filter_for(viewer, 'spoilerword')
    status = Fabricate(:status, account: author, text: 'body', spoiler_text: 'spoilerword')

    results = apply_filters(viewer, status)

    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include('spoilerword')
  end

  it 'uses the original status for a reblog' do
    keyword_filter_for(viewer, 'innerword')
    original = Fabricate(:status, account: author, text: 'innerword')
    reblog = Fabricate(:status, account: author, reblog: original)

    results = apply_filters(viewer, reblog)

    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include('innerword')
  end

  it 'matches a referenced URL on a reblog of the referencing status' do
    referenced = Fabricate(:status, account: author, text: 'original')
    referencing = Fabricate(:status, account: author, text: 'see this')
    Fabricate(:status_reference, status: referencing, target_status: referenced)
    reblog = Fabricate(:status, account: author, reblog: referencing)
    referenced_url = ActivityPub::TagManager.instance.url_for(referenced)
    keyword_filter_for(viewer, referenced_url)

    results = apply_filters(viewer, reblog)

    expect(results.length).to eq 1
    expect(results.first.keyword_matches).to include(referenced_url)
  end
end
