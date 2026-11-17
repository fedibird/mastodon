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

    it 'resumes a keyed pending operation instead of treating it as a duplicate' do
      allow(Reboost::FederationWorker).to receive(:perform_async)
      boost = described_class.new.call(account, original)
      boost.discard
      operation = ReboostOperation.create!(
        account: account,
        reblog_of_id: original.id,
        old_status_id: boost.id,
        state: 'pending',
        reboost: true,
        idempotency_key: 'again',
        visibility: boost.visibility,
        undo_payload: '{"type":"Undo"}',
        undo_inboxes: ['https://remote.example/inbox'],
        options: { 'audience' => [] }
      )
      RedisConfiguration.with { |redis| redis.set("idempotency:reboost:#{account.id}:again", "operation:#{operation.id}") }

      travel 301.seconds do
        result = Reboost::Placement.resume!(operation)

        expect(result.id).not_to eq boost.id
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
        expect(operation.reload.state).to eq 'federating'
        expect(operation.new_status_id).to eq result.id
        expect(operation.undo_payload).to be_present
        expect(Reboost::FederationWorker).to have_received(:perform_in).with(Reboost::FEDERATION_GAP, operation.id)
        expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async).with(result.id)
      end
    end

    it 'does not recreate a wrapper when the author would now refuse the boost' do
      operation = ReboostOperation.create!(
        account: account,
        reblog_of_id: original.id,
        state: 'pending',
        reboost: true,
        undo_inboxes: [],
        options: {}
      )
      refusal = instance_double(StatusPolicy, reblog?: false)
      allow(StatusPolicy).to receive(:new).with(account, original).and_return(refusal)

      expect(Reboost::Placement.resume!(operation)).to be_nil
      expect(operation.reload).to have_attributes(state: 'failed', error_code: 'not_permitted')
      expect(account.statuses.where(reblog_of_id: original.id).pluck(:id)).to eq [first.id]
    end

    it 'removes an unannounced replacement when mention processing fails' do
      allow(Reboost::FederationWorker).to receive(:perform_async)
      allow_any_instance_of(ProcessMentionsService).to receive(:call).and_wrap_original do |method, status, *args|
        raise Mastodon::ValidationError, 'mentions failed' if status.reblog_of_id == original.id && status.id != first.id

        method.call(status, *args)
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true) }.to raise_error(Mastodon::ValidationError, 'mentions failed')
      end

      expect(account.statuses.where(reblog_of_id: original.id)).to be_empty
      expect(ReboostOperation.order(:id).last.error_code).to eq 'create_failed'
      expect(Reboost::FederationWorker).to have_received(:perform_async)
    end

    it 'does not commit a replacement after cancellation takes the placement lock' do
      first.discard
      operation = ReboostOperation.create!(
        account: account,
        reblog_of_id: original.id,
        old_status_id: first.id,
        state: 'pending',
        reboost: true,
        idempotency_key: 'again',
        undo_payload: '{"type":"Undo"}',
        undo_inboxes: ['https://remote.example/inbox'],
        options: {}
      )
      RedisConfiguration.with { |redis| redis.set("idempotency:reboost:#{account.id}:again", "operation:#{operation.id}") }
      expect(RedisLock).to receive(:acquire).with(hash_including(key: "lock:reboost:#{account.id}:#{original.id}")).at_least(:once).and_call_original

      Reboost::Placement.cancel_pending!(account, original.id)

      travel 301.seconds do
        expect(Reboost::Placement.resume!(operation)).to be_nil
      end
      expect(operation.reload).to have_attributes(state: 'cancelled', error_code: 'unreblogged')
      expect(account.statuses.where(reblog_of_id: original.id)).to be_empty
    end

    it 'keeps the saved Undo when the replacement cannot be created' do
      allow(Reboost::FederationWorker).to receive(:perform_async)
      described_class.new.call(account, original)
      allow_any_instance_of(Reboost::Placement).to receive(:create_reblog!).and_raise(Mastodon::ValidationError, 'nope')

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true) }.to raise_error(Mastodon::ValidationError)
      end

      operation = ReboostOperation.order(:id).last
      expect(operation.undo_payload).to be_present
      expect(operation.error_code).to eq 'create_failed'
      expect(operation.new_status_id).to be_nil
      expect(Reboost::FederationWorker).to have_received(:perform_async).with(operation.id)
      expect(Status.find_by(id: first.id)).to be_nil
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
