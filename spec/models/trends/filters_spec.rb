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

    it 'rejects an unknown filter' do
      expect { described_class.new(status: 'approved').results.to_a }.to raise_error(Mastodon::InvalidParameterError, 'Unknown filter: status')
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

    it 'rejects an unknown filter' do
      expect { described_class.new(status: 'approved').results.to_a }.to raise_error(Mastodon::InvalidParameterError, 'Unknown filter: status')
    end
  end

  describe Trends::PreviewCardProviderFilter do
    let!(:approved) { PreviewCardProvider.create!(domain: 'approved.example', trendable: true, reviewed_at: Time.now.utc) }
    let!(:rejected) { PreviewCardProvider.create!(domain: 'rejected.example', trendable: false, reviewed_at: Time.now.utc) }
    let!(:pending) { PreviewCardProvider.create!(domain: 'pending.example', trendable: nil, reviewed_at: nil) }

    it 'orders every provider by domain and filters review state' do
      expect(described_class.new({}).results.map(&:domain)).to eq %w(approved.example pending.example rejected.example)
      expect(described_class.new(status: 'approved').results.map(&:domain)).to eq %w(approved.example)
      expect(described_class.new(status: 'rejected').results.map(&:domain)).to eq %w(rejected.example)
      expect(described_class.new(status: 'pending_review').results.map(&:domain)).to eq %w(pending.example)
    end

    it 'rejects an unknown status' do
      expect { described_class.new(status: 'nope').results.to_a }.to raise_error(Mastodon::InvalidParameterError, 'Unknown status: nope')
    end
  end
end
