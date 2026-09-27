# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trends review filters' do # rubocop:disable Metrics/BlockLength
  describe Trends::TagFilter do
    let!(:pending) { Fabricate(:tag, name: 'pendingtag', trendable: nil, reviewed_at: nil, requested_review_at: Time.now.utc) }
    let!(:approved) { Fabricate(:tag, name: 'approvedtag', trendable: true, reviewed_at: Time.now.utc) }
    let!(:rejected) { Fabricate(:tag, name: 'rejectedtag', trendable: false, reviewed_at: Time.now.utc) }

    before do
      redis.zadd('trending_tags:all', 5, approved.id)
      redis.zadd('trending_tags:all', 4, rejected.id)
    end

    it 'starts pending review from Tag.unscoped instead of the trending set' do
      ids = described_class.new(status: 'pending_review').results.pluck(:id)

      expect(ids).to include(pending.id)
      expect(ids).not_to include(approved.id, rejected.id)
    end

    it 'limits approved and rejected tags to the trending set' do
      expect(described_class.new(status: 'approved').results.pluck(:id)).to eq [approved.id]
      expect(described_class.new(status: 'rejected').results.pluck(:id)).to eq [rejected.id]
    end

    it 'treats an explicit all status as the trending set' do
      expect(described_class.new(status: 'all').results.pluck(:id)).to contain_exactly(approved.id, rejected.id)
    end

    it 'rejects an unknown status' do
      expect { described_class.new(status: 'nope').results.to_a }.to raise_error(RuntimeError, 'Unknown status: nope')
    end

    it 'rejects an unknown filter' do
      expect { described_class.new(trending: 'all').results.to_a }.to raise_error(RuntimeError, 'Unknown filter: trending')
    end
  end

  describe Trends::PreviewCardFilter do
    let!(:allowed) { Fabricate(:preview_card, language: 'en', title: 'Allowed') }
    let!(:hidden) { Fabricate(:preview_card, language: 'ja', title: 'Hidden') }

    before do
      PreviewCardTrend.create!(preview_card: allowed, score: 2, rank: 2, allowed: true, language: 'en')
      PreviewCardTrend.create!(preview_card: hidden, score: 9, rank: 1, allowed: false, language: 'ja')
    end

    it 'returns every trending link by score, then only allowed links' do
      expect(described_class.new({}).results.map(&:title)).to eq %w(Hidden Allowed)
      expect(described_class.new(trending: 'allowed').results.map(&:title)).to eq %w(Allowed)
    end

    it 'filters by locale' do
      expect(described_class.new(locale: 'ja').results.map(&:title)).to eq %w(Hidden)
    end

    it 'filters review state without loading every preview card' do
      pending = Fabricate(:preview_card, url: 'https://pending.example/a', title: 'Pending card', trendable: nil)
      approved_card = Fabricate(:preview_card, url: 'https://approved.example/a', title: 'Approved card', trendable: nil)
      rejected_card = Fabricate(:preview_card, url: 'https://rejected.example/a', title: 'Rejected card', trendable: nil)
      override = Fabricate(:preview_card, url: 'https://parent.example/child', title: 'Override card', trendable: true)
      inherited = Fabricate(:preview_card, url: 'https://news.parent.example/story', title: 'Inherited card', trendable: nil)
      PreviewCardProvider.create!(domain: 'approved.example', trendable: true, reviewed_at: Time.now.utc)
      PreviewCardProvider.create!(domain: 'rejected.example', trendable: false, reviewed_at: Time.now.utc)
      PreviewCardProvider.create!(domain: 'pending.example', trendable: true, reviewed_at: nil)
      PreviewCardProvider.create!(domain: 'parent.example', trendable: false, reviewed_at: Time.now.utc)
      [pending, approved_card, rejected_card, override, inherited].each_with_index do |card, index|
        PreviewCardTrend.create!(preview_card: card, score: 10 - index, rank: index + 1, allowed: false, language: 'en')
      end

      expect(described_class.new(status: 'pending_review').results.map(&:title)).to include('Pending card', 'Hidden', 'Allowed')
      expect(described_class.new(status: 'pending_review').results.map(&:title)).not_to include('Approved card', 'Rejected card', 'Override card', 'Inherited card')
      expect(described_class.new(status: 'approved').results.map(&:title)).to contain_exactly('Approved card', 'Override card')
      expect(described_class.new(status: 'rejected').results.map(&:title)).to contain_exactly('Rejected card', 'Inherited card')
      expect(described_class.new(status: 'all').results.map(&:title)).to include('Pending card', 'Approved card', 'Rejected card', 'Override card', 'Inherited card', 'Hidden', 'Allowed')
    end

    it 'keeps review state independent from locale and the publication filter' do
      expect(described_class.new(status: 'all', locale: 'ja', trending: 'allowed').results.map(&:title)).to eq []
      expect(described_class.new(status: 'all', locale: 'en', trending: 'allowed').results.map(&:title)).to eq %w(Allowed)
    end

    it 'rejects an unknown status' do
      expect { described_class.new(status: 'nope').results.to_a }.to raise_error(Mastodon::InvalidParameterError, 'Unknown status: nope')
    end
  end

  describe Trends::StatusFilter do
    let(:allowed_account) { Fabricate(:account) }
    let(:hidden_account) { Fabricate(:account) }
    let!(:allowed) { Fabricate(:status, account: allowed_account, language: 'en', text: 'Allowed') }
    let!(:hidden) { Fabricate(:status, account: hidden_account, language: 'ja', text: 'Hidden') }

    before do
      StatusTrend.create!(status: allowed, account: allowed_account, score: 2, rank: 2, allowed: true, language: 'en')
      StatusTrend.create!(status: hidden, account: hidden_account, score: 9, rank: 1, allowed: false, language: 'ja')
    end

    it 'returns every trending status by score, then only allowed statuses' do
      expect(described_class.new({}).results.map(&:id)).to eq [hidden.id, allowed.id]
      expect(described_class.new(trending: 'allowed').results.map(&:id)).to eq [allowed.id]
    end

    it 'filters by locale' do
      expect(described_class.new(locale: 'en').results.map(&:id)).to eq [allowed.id]
    end

    it 'filters review state from the status and its account' do
      Setting.trendable_by_default = false
      reviewed = Fabricate(:account, trendable: true, reviewed_at: Time.now.utc)
      blocked = Fabricate(:account, trendable: false, reviewed_at: Time.now.utc)
      default_rejected = Fabricate(:account, trendable: nil, reviewed_at: Time.now.utc)
      unreviewed = Fabricate(:account, trendable: true, reviewed_at: nil)
      approved_status = Fabricate(:status, account: reviewed, trendable: nil, text: 'Approved status')
      rejected_status = Fabricate(:status, account: blocked, trendable: nil, text: 'Rejected status')
      inherited_default = Fabricate(:status, account: default_rejected, trendable: nil, text: 'Default rejected')
      pending_status = Fabricate(:status, account: unreviewed, trendable: nil, text: 'Pending status')
      override = Fabricate(:status, account: blocked, trendable: true, text: 'Override status')
      [approved_status, rejected_status, inherited_default, pending_status, override].each_with_index do |status, index|
        StatusTrend.create!(status: status, account: status.account, score: 10 - index, rank: index + 1, allowed: false, language: 'en')
      end

      expect(described_class.new(status: 'approved').results.map(&:id)).to contain_exactly(approved_status.id, override.id)
      expect(described_class.new(status: 'rejected').results.map(&:id)).to contain_exactly(rejected_status.id, inherited_default.id)
      expect(described_class.new(status: 'pending_review').results.map(&:id)).to include(pending_status.id, allowed.id, hidden.id)
      expect(described_class.new(status: 'pending_review').results.map(&:id)).not_to include(approved_status.id, rejected_status.id, override.id)
      expect(described_class.new(status: 'all').results.map(&:id)).to include(approved_status.id, rejected_status.id, pending_status.id, override.id, allowed.id)

      Setting.trendable_by_default = true
      expect(described_class.new(status: 'approved').results.map(&:id)).to include(inherited_default.id)
      expect(described_class.new(status: 'rejected').results.map(&:id)).not_to include(inherited_default.id)
    end

    it 'keeps review state independent from locale and the publication filter' do
      expect(described_class.new(status: 'pending_review', locale: 'en', trending: 'allowed').results.map(&:id)).to eq [allowed.id]
      expect(described_class.new(status: 'pending_review', locale: 'ja', trending: 'allowed').results.map(&:id)).to eq []
    end

    it 'rejects an unknown status' do
      expect { described_class.new(status: 'nope').results.to_a }.to raise_error(Mastodon::InvalidParameterError, 'Unknown status: nope')
    end
  end

  describe Trends::PreviewCardProviderFilter do
    let!(:approved) { PreviewCardProvider.create!(domain: 'approved.example', trendable: true, reviewed_at: Time.now.utc) }
    let!(:rejected) { PreviewCardProvider.create!(domain: 'rejected.example', trendable: false, reviewed_at: Time.now.utc) }
    let!(:pending) { PreviewCardProvider.create!(domain: 'pending.example', trendable: nil, reviewed_at: nil) }

    it 'orders every provider by domain and filters review state' do
      expect(described_class.new({}).results.map(&:domain)).to eq %w(approved.example pending.example rejected.example)
      expect(described_class.new(status: 'all').results.map(&:domain)).to eq %w(approved.example pending.example rejected.example)
      expect(described_class.new(status: 'approved').results.map(&:domain)).to eq %w(approved.example)
      expect(described_class.new(status: 'rejected').results.map(&:domain)).to eq %w(rejected.example)
      expect(described_class.new(status: 'pending_review').results.map(&:domain)).to eq %w(pending.example)
    end

    it 'rejects an unknown status' do
      expect { described_class.new(status: 'nope').results.to_a }.to raise_error(Mastodon::InvalidParameterError, 'Unknown status: nope')
    end
  end
end
