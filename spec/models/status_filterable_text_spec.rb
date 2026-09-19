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

  it 'includes searchable body text' do
    status = Fabricate(:status, account: local_account, text: 'hello foo')

    expect(status.filterable_text).to include('hello foo')
    expect(status.filterable_text).to include(status.searchable_text)
  end

  it 'does not include ordinary body URLs' do
    status = Fabricate(:status, account: local_account, text: 'hello https://example.com/article')

    expect(status.searchable_text).not_to include('example.com')
    expect(status.filterable_text).not_to include('example.com')
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

  it 'keeps spoiler and poll options from searchable_text' do
    status = Fabricate(:status, account: local_account, text: 'body', spoiler_text: 'spoilerword')
    poll = Fabricate(:poll, account: local_account, status: status, options: %w(Alpha Bravo))
    status.update!(poll_id: poll.id)

    expect(status.filterable_text).to include('spoilerword')
    expect(status.filterable_text).to include('Alpha')
  end

  it 'does not query status_references when they are already loaded' do
    referenced = Fabricate(:status, account: local_account, text: 'original')
    referencing = Fabricate(:status, account: local_account, text: 'see this')
    Fabricate(:status_reference, status: referencing, target_status: referenced)

    sqls = sql_with_loaded_references(referencing)

    expect(sqls.grep(/status_references/i)).to eq([])
  end
end
