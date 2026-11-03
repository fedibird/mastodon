require 'rails_helper'

RSpec.describe EntityCache do
  let(:local_account)  { Fabricate(:account, domain: nil, username: 'alice') }
  let(:remote_account) { Fabricate(:account, domain: 'remote.test', username: 'bob', url: 'https://remote.test/') }

  describe '#emoji' do
    subject { EntityCache.instance.emoji(shortcodes, domain) }

    context 'called with an empty list of shortcodes' do
      let(:shortcodes) { [] }
      let(:domain)     { 'example.org' }

      it 'returns an empty array' do
        is_expected.to eq []
      end
    end
  end

  describe '#status' do
    it 'does not conflate fetched URLs differing only in the case of their paths' do
      upper = 'https://remote.test/objects/AbC'
      lower = 'https://remote.test/objects/abc'
      remote = instance_double(FetchRemoteStatusService)
      allow(FetchRemoteStatusService).to receive(:new).and_return(remote)
      allow(remote).to receive(:call).with(upper).and_return(:upper)
      allow(remote).to receive(:call).with(lower).and_return(:lower)

      expect(described_class.instance.status(upper)).to eq(:upper)
      expect(described_class.instance.status(lower)).to eq(:lower)
    end
  end

  describe '#holding_status' do
    let(:aggregator) { Fabricate(:account, domain: 'aggregator.test', username: 'relay') }

    it 'does not resolve an article URL from an aggregator status.url claim' do
      url = 'https://publisher.test/articles/entity-cache-1'
      Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/a1', url: url)

      expect(described_class.instance.holding_status(url)).to be_nil
    end

    it 'ignores old cached URL aliases from before the identity policy changed' do
      url = 'https://publisher.test/articles/legacy-alias'
      Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/old', url: url)
      # ActiveRecord status objects can contain non-marshallable Proc state in
      # this test environment; a simple sentinel tests the legacy-key fence.
      Rails.cache.write(described_class.instance.to_key(:holding_status, url), 'legacy mapping')

      expect(described_class.instance.holding_status(url)).to be_nil
    end

    it 'keeps distinct cache entries for case-sensitive URL paths' do
      url = 'https://aggregator.test/@relay/AbC123'
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/users/relay/statuses/AbC123', url: url)

      expect(described_class.instance.holding_status(url)).to eq(status)
      expect(described_class.instance.holding_status('https://aggregator.test/@relay/abc123')).to be_nil
    end

    it 'can cache an independently discovered AP alternate after a negative lookup' do
      link = 'https://publisher.test/articles/with-alternate'
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/discovered', url: 'https://aggregator.test/@relay/discovered')

      expect(described_class.instance.holding_status(link)).to be_nil
      described_class.instance.update_holding_status(link, status)
      expect(described_class.instance.holding_status(link)).to eq(status)
    end

    it 'reuses a cached status without another database query when formatting the same link' do
      url = 'https://aggregator.test/@relay/765'
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/users/relay/statuses/765', url: url)
      expect(described_class.instance.holding_status(url)).to eq(status)

      expect(Status).not_to receive(:find_by)
      expect(described_class.instance.holding_status(url)).to eq(status)
    end

    it 'resolves the canonical AP URI regardless of the remote display URL' do
      status = Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/direct', url: 'https://publisher.test/articles/direct')

      expect(described_class.instance.holding_status(status.uri)).to eq(status)
    end
  end

  describe '#holding_account' do
    it 'reuses a cached profile alias without querying the account table' do
      account = Fabricate(:account, domain: 'aggregator.test', username: 'relay', uri: 'https://aggregator.test/users/relay', url: 'https://aggregator.test/@relay')
      expect(described_class.instance.holding_account(account.url)).to eq(account)

      expect(Account).not_to receive(:find_by)
      expect(described_class.instance.holding_account(account.url)).to eq(account)
    end

    it 'does not resolve a third-party profile link claimed by a remote actor' do
      account = Fabricate(:account, domain: 'aggregator.test', username: 'relay', uri: 'https://aggregator.test/users/relay', url: 'https://publisher.test/profiles/relay')

      expect(described_class.instance.holding_account('https://publisher.test/profiles/relay')).to be_nil
      expect(described_class.instance.holding_account(account.uri)).to eq(account)
    end
  end
end
