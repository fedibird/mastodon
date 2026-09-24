# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trends review batches' do # rubocop:disable Metrics/BlockLength
  let(:actor) { user_with_role(role).account }
  let(:role) do
    UserRole.create!(
      name: "Trends batch #{SecureRandom.hex(4)}",
      position: UserRole.maximum(:position).to_i + 1,
      permissions_as_keys: %w(manage_taxonomies)
    )
  end

  describe Trends::TagBatch do
    let(:tag) { Fabricate(:tag, name: 'batchtag', trendable: nil, reviewed_at: nil) }

    it 'approves tags and records reviewed_at' do
      described_class.new(tag_ids: [tag.id], action: 'approve', current_account: actor).save

      tag.reload
      expect(tag[:trendable]).to be true
      expect(tag.reviewed_at).to be_present
    end

    it 'rejects tags and records reviewed_at' do
      described_class.new(tag_ids: [tag.id], action: 'reject', current_account: actor).save

      tag.reload
      expect(tag[:trendable]).to be false
      expect(tag.reviewed_at).to be_present
    end
  end

  describe Trends::PreviewCardBatch do
    let(:card) { Fabricate(:preview_card, url: 'https://news.example/story', trendable: true) }

    it 'approves and rejects only the individual trendable flag' do
      described_class.new(preview_card_ids: [card.id], action: 'approve', current_account: actor).save
      expect(card.reload[:trendable]).to be true

      described_class.new(preview_card_ids: [card.id], action: 'reject', current_account: actor).save
      expect(card.reload[:trendable]).to be false
      expect(card.attributes).not_to have_key('reviewed_at')
    end

    it 'creates a missing provider, records reviewed_at, and clears the individual override' do
      expect(PreviewCardProvider.find_by(domain: 'news.example')).to be_nil

      described_class.new(preview_card_ids: [card.id], action: 'approve_providers', current_account: actor).save

      provider = PreviewCardProvider.find_by!(domain: 'news.example')
      expect(provider[:trendable]).to be true
      expect(provider.reviewed_at).to be_present
      expect(card.reload[:trendable]).to be_nil
      expect(card.trendable?).to be true
    end

    it 'rejects the provider and lets that decision win after the override is cleared' do
      described_class.new(preview_card_ids: [card.id], action: 'reject_providers', current_account: actor).save

      provider = PreviewCardProvider.find_by!(domain: 'news.example')
      expect(provider[:trendable]).to be false
      expect(provider.reviewed_at).to be_present
      expect(card.reload[:trendable]).to be_nil
      expect(card.trendable?).to be false
    end
  end

  describe Trends::StatusBatch do
    let(:account) { Fabricate(:account, trendable: nil, reviewed_at: nil) }
    let(:status) { Fabricate(:status, account: account, trendable: true) }

    it 'approves and rejects only the individual status' do
      described_class.new(status_ids: [status.id], action: 'approve', current_account: actor).save
      expect(status.reload[:trendable]).to be true
      expect(account.reload.reviewed_at).to be_nil

      described_class.new(status_ids: [status.id], action: 'reject', current_account: actor).save
      expect(status.reload[:trendable]).to be false
      expect(status.attributes).not_to have_key('reviewed_at')
    end

    it 'approves the account, records reviewed_at, and clears the individual override' do
      described_class.new(status_ids: [status.id], action: 'approve_accounts', current_account: actor).save

      expect(account.reload[:trendable]).to be true
      expect(account.reviewed_at).to be_present
      expect(status.reload[:trendable]).to be_nil
      expect(status.trendable?).to be true
    end

    it 'rejects the account and lets that decision win after the override is cleared' do
      described_class.new(status_ids: [status.id], action: 'reject_accounts', current_account: actor).save

      expect(account.reload[:trendable]).to be false
      expect(account.reviewed_at).to be_present
      expect(status.reload[:trendable]).to be_nil
      expect(status.trendable?).to be false
    end
  end

  describe Trends::PreviewCardProviderBatch do
    let(:provider) { PreviewCardProvider.create!(domain: 'publisher.example', trendable: nil, reviewed_at: nil) }

    it 'approves and rejects the provider and records reviewed_at' do
      described_class.new(preview_card_provider_ids: [provider.id], action: 'approve', current_account: actor).save
      expect(provider.reload[:trendable]).to be true
      expect(provider.reviewed_at).to be_present

      described_class.new(preview_card_provider_ids: [provider.id], action: 'reject', current_account: actor).save
      expect(provider.reload[:trendable]).to be false
      expect(provider.reviewed_at).to be_present
    end
  end
end
