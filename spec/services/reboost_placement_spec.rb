# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReblogService do
  let(:user) { Fabricate(:user, current_sign_in_at: Time.now.utc) }
  let(:account) { user.account }
  let(:original) { Fabricate(:status, account: account) }

  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(Reboost::FederationWorker).to receive(:perform_in)
  end

  describe 'a first boost' do
    it 'creates one boost and starts the cooldown' do
      boost = described_class.new.call(account, original)

      expect(boost.reblog_of_id).to eq original.id
      expect(original.reblogs.count).to eq 1
      expect(ReboostCooldown.remaining_seconds(account.id, original.id)).to be_positive
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(boost.id)
      expect(Reboost::FederationWorker).not_to have_received(:perform_in)
    end

    it 'returns the same boost when repeated' do
      first = described_class.new.call(account, original)
      second = described_class.new.call(account, original)

      expect(second.id).to eq first.id
      expect(original.reload.reblogs_count).to eq 1
    end
  end

  describe 'reboost' do
    let!(:first) { described_class.new.call(account, original, visibility: 'private') }

    it 'replaces the wrapper after the cooldown and keeps a single boost' do
      travel 301.seconds do
        replacement = described_class.new.call(account, original, reboost: true)

        expect(replacement.id).not_to eq first.id
        expect(Status.find_by(id: first.id)).to be_nil
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
        expect(original.reload.reblogs_count).to eq 1
        expect(replacement.visibility).to eq 'private'
        expect(Reboost::FederationWorker).to have_received(:perform_in)
        expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(first.id)
        expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async).with(replacement.id)
      end
    end

    it 'rejects a reboost inside the cooldown without removing the current boost' do
      expect { described_class.new.call(account, original, reboost: true) }.to raise_error(Mastodon::ReboostCooldownError) do |error|
        expect(error.retry_after).to be_between(1, Reboost::COOLDOWN_SECONDS)
      end
      expect(Status.find_by(id: first.id)).to be_present
    end

    it 'rejects an ordinary boost after unreblog until the cooldown ends' do
      first.discard

      expect { described_class.new.call(account, original) }.to raise_error(Mastodon::ReboostCooldownError)
      expect(Status.unscoped.find_by(id: first.id).deleted_at).to be_present

      travel 301.seconds do
        replacement = described_class.new.call(account, original)
        expect(replacement.id).not_to eq first.id
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
      end
    end

    it 'does not widen visibility when the request omits it' do
      travel 301.seconds do
        replacement = described_class.new.call(account, original, reboost: true, visibility: 'public', visibility_explicit: true)
        expect(replacement.visibility).to eq 'public'
      end
    end

    it 'keeps the old boost when the requested visibility is prohibited' do
      user.settings.prohibited_visibilities = ['public']

      expect do
        described_class.new.call(account, original, reboost: true, visibility: 'public', visibility_explicit: true)
      end.to raise_error(Mastodon::ValidationError)
      expect(Status.find_by(id: first.id)).to be_present
    end

    it 'replays an idempotency key as the same wrapper' do
      travel 301.seconds do
        first_try = described_class.new.call(account, original, reboost: true, idempotency: 'again')
        second_try = described_class.new.call(account, original, reboost: true, idempotency: 'again')
        expect(second_try.id).to eq first_try.id
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
      end
    end
  end

  describe 'acceptance policy' do
    it 'rejects reboost while conservative and unset, and still allows the first boost' do
      user.settings.new_features_policy = 'conservative'
      user.save!

      boost = described_class.new.call(account, original)
      expect(boost).to be_persisted

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true) }.to raise_error(Mastodon::ReboostDisabledError)
      end
      expect(Status.where(reblog_of_id: original.id).count).to eq 1
    end

    it 'lets an explicit on win over a conservative policy' do
      user.settings.new_features_policy = 'conservative'
      user.settings.enable_reboost = true

      described_class.new.call(account, original)
      travel 301.seconds do
        expect(described_class.new.call(account, original, reboost: true)).to be_persisted
      end
    end
  end
end
