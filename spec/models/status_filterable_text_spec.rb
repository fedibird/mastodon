# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Status, '#filterable_text', type: :model do # rubocop:disable Metrics/BlockLength
  let(:local_account) { Fabricate(:account, domain: nil, username: 'alice') }

  def sql_with_loaded_references(status)
    status.references.to_a
    sqls = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      sqls << sql unless sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      status.filterable_text
    end

    sqls
  end

  def stub_tag_manager_nil(method_name, target)
    allow(ActivityPub::TagManager.instance).to receive(method_name).and_wrap_original do |original, actual|
      actual.id == target.id ? nil : original.call(actual)
    end
  end

  it 'includes searchable body text' do
    status = Fabricate(:status, account: local_account, text: 'hello foo')

    expect(status.filterable_text).to include('hello foo')
    expect(status.filterable_text).to include(status.searchable_text)
  end

  it 'includes ordinary body URLs that searchable_text strips' do
    status = Fabricate(:status, account: local_account, text: 'hello https://example.com/article')

    expect(status.searchable_text).not_to include('example.com')
    expect(status.filterable_text).to include('https://example.com/article')
  end

  it 'includes ordinary remote HTML anchor URLs that searchable_text strips' do
    remote_account = Fabricate(:account, domain: 'remote.test', username: 'bob', url: 'https://remote.test/@bob')
    html = '<p>hello <a href="https://example.com/article">https://example.com/article</a></p>'
    status = Fabricate(:status, account: remote_account, text: html)

    expect(status.searchable_text).not_to include('example.com')
    expect(status.filterable_text).to include('https://example.com/article')
  end

  it 'includes referenced status URL and URI without putting them in searchable_text' do
    referenced = Fabricate(:status, account: local_account, text: 'original')
    referencing = Fabricate(:status, account: local_account, text: 'see this')
    Fabricate(:status_reference, status: referencing, target_status: referenced)

    url = ActivityPub::TagManager.instance.url_for(referenced)
    uri = ActivityPub::TagManager.instance.uri_for(referenced)

    expect(referencing.searchable_text).not_to include(url)
    expect(referencing.searchable_text).not_to include(uri)
    expect(referencing.filterable_text).to include(url)
    expect(referencing.filterable_text).to include(uri)
  end

  it 'includes distinct remote URL and URI for a referenced status' do
    remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
    referenced = Fabricate(
      :status,
      account: remote,
      text: 'remote original',
      uri: 'https://example.social/users/bob/statuses/123',
      url: 'https://example.social/@bob/123'
    )
    referencing = Fabricate(:status, account: local_account, text: 'see remote')
    Fabricate(:status_reference, status: referencing, target_status: referenced)

    expect(referencing.filterable_text).to include('https://example.social/@bob/123')
    expect(referencing.filterable_text).to include('https://example.social/users/bob/statuses/123')
    expect(referencing.searchable_text).not_to include('example.social')
  end

  it 'falls back to the source URL when url_for is nil' do
    remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
    referenced = Fabricate(
      :status,
      account: remote,
      text: 'remote original',
      uri: 'https://example.social/users/bob/statuses/123',
      url: 'https://example.social/@bob/123'
    )
    source_url = referenced.url
    referencing = Fabricate(:status, account: local_account, text: "see #{source_url}")
    Fabricate(:status_reference, status: referencing, target_status: referenced)
    stub_tag_manager_nil(:url_for, referenced)

    expect(referencing.urls).to include(source_url)
    expect(referencing.filterable_text).to include(source_url)
    expect(referencing.filterable_text).to include(referenced.uri)
  end

  it 'falls back to the source URL when uri_for is nil' do
    remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
    referenced = Fabricate(
      :status,
      account: remote,
      text: 'remote original',
      uri: 'https://example.social/users/bob/statuses/123',
      url: 'https://example.social/@bob/123'
    )
    source_url = referenced.url
    referencing = Fabricate(:status, account: local_account, text: "see #{source_url}")
    Fabricate(:status_reference, status: referencing, target_status: referenced)
    stub_tag_manager_nil(:uri_for, referenced)

    expect(referencing.urls).to include(source_url)
    expect(referencing.filterable_text).to include(source_url)
    expect(referencing.filterable_text).to include(ActivityPub::TagManager.instance.url_for(referenced))
  end

  it 'collapses duplicate URL forms' do
    remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
    referenced = Fabricate(
      :status,
      account: remote,
      text: 'remote original',
      uri: 'https://example.social/users/bob/statuses/123',
      url: 'https://example.social/@bob/123'
    )
    referencing = Fabricate(:status, account: local_account, text: "see #{referenced.url} #{referenced.url}")
    Fabricate(:status_reference, status: referencing, target_status: referenced)

    expect(referencing.filterable_urls.count(referenced.url)).to eq 1
    expect(referencing.filterable_urls.count(referenced.uri)).to eq 1
  end

  it 'uses the original status filterable_text for reblogs, including ordinary URLs' do
    original = Fabricate(:status, account: local_account, text: 'innerword https://example.com/article')
    reblog = Fabricate(:status, account: local_account, reblog: original)

    expect(reblog.proper.filterable_text).to eq original.filterable_text
    expect(reblog.proper.filterable_text).to include('innerword')
    expect(reblog.proper.filterable_text).to include('https://example.com/article')
    expect(reblog.proper.searchable_text).not_to include('example.com')
  end

  it 'keeps spoiler and poll options from searchable_text' do
    status = Fabricate(:status, account: local_account, text: 'body', spoiler_text: 'spoilerword')
    poll = Fabricate(:poll, account: local_account, status: status, options: %w(Alpha Bravo))
    status.update!(poll_id: poll.id)

    expect(status.filterable_text).to include('spoilerword')
    expect(status.filterable_text).to include('Alpha')
  end

  # A URL is stored and matched in its canonical percent-encoded form, which does
  # not read like the link a user sees. Every canonical URL therefore carries its
  # display form as an additional filterable representation.
  describe 'human-readable URL variants' do
    it 'adds the display form of a percent-encoded body URL after the canonical one' do
      status = Fabricate(:status, account: local_account, text: 'look https://example.com/%E6%9D%B1%E4%BA%AC/page')

      expect(status.filterable_urls).to eq [
        'https://example.com/%E6%9D%B1%E4%BA%AC/page',
        'https://example.com/東京/page',
      ]
    end

    it 'adds the display form of a percent-encoded query value' do
      status = Fabricate(:status, account: local_account, text: 'look https://example.com/search?q=%E6%9D%B1%E4%BA%AC')

      expect(status.filterable_urls).to eq [
        'https://example.com/search?q=%E6%9D%B1%E4%BA%AC',
        'https://example.com/search?q=東京',
      ]
    end

    it 'adds no variant for an ASCII URL whose display form is identical' do
      status = Fabricate(:status, account: local_account, text: 'look https://example.com/article?page=2')

      expect(status.filterable_urls).to eq ['https://example.com/article?page=2']
    end

    it 'keeps only the canonical form when decoding would produce invalid UTF-8' do
      status = Fabricate(:status, account: local_account, text: 'look https://example.com/%FF/page')

      expect(status.filterable_urls).to eq ['https://example.com/%FF/page']
    end

    it 'keeps only the canonical form when decoding would produce a control character' do
      status = Fabricate(:status, account: local_account, text: 'look https://example.com/%00/page')

      expect(status.filterable_urls).to eq ['https://example.com/%00/page']
      expect(status.filterable_urls.join).not_to include KeywordSubscribe::MatchingText::SEPARATOR
    end

    it 'adds display forms for a referenced status canonical URL and ActivityPub URI' do
      remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
      referenced = Fabricate(
        :status,
        account: remote,
        text: 'remote original',
        uri: 'https://example.social/users/%E6%9D%B1%E4%BA%AC/statuses/123',
        url: 'https://example.social/@%E6%9D%B1%E4%BA%AC/123'
      )
      referencing = Fabricate(:status, account: local_account, text: "see #{referenced.url}")
      Fabricate(:status_reference, status: referencing, target_status: referenced)

      expect(referencing.filterable_urls).to eq [
        'https://example.social/@%E6%9D%B1%E4%BA%AC/123',
        'https://example.social/@東京/123',
        'https://example.social/users/%E6%9D%B1%E4%BA%AC/statuses/123',
        'https://example.social/users/東京/statuses/123',
      ]
    end

    it 'does not let a display variant change which reference a URL resolves to' do
      remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
      referenced = Fabricate(
        :status,
        account: remote,
        text: 'remote original',
        uri: 'https://example.social/users/bob/statuses/%E6%9D%B1%E4%BA%AC',
        url: 'https://example.social/@bob/%E6%9D%B1%E4%BA%AC'
      )
      referencing = Fabricate(:status, account: local_account, text: "see #{referenced.url}")
      Fabricate(:status_reference, status: referencing, target_status: referenced)

      expect(referencing.references).to eq [referenced]
      expect(referencing.urls).to eq [referenced.url]
      expect(referencing.filterable_urls.first).to eq referenced.url
      expect(referencing.filterable_urls).to include referenced.uri
    end

    it 'exposes both representations through filterable_text' do
      status = Fabricate(:status, account: local_account, text: 'look https://example.com/%E6%9D%B1%E4%BA%AC/page')

      expect(status.filterable_text).to include 'https://example.com/%E6%9D%B1%E4%BA%AC/page'
      expect(status.filterable_text).to include 'https://example.com/東京/page'
    end
  end

  it 'does not query status_references when they are already loaded' do
    referenced = Fabricate(:status, account: local_account, text: 'original')
    referencing = Fabricate(:status, account: local_account, text: 'see this')
    Fabricate(:status_reference, status: referencing, target_status: referenced)

    sqls = sql_with_loaded_references(referencing)

    expect(sqls.grep(/status_references/i)).to eq([])
  end
end
