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

    it 'keeps a reported boost soft-deleted when boosting again after unreblog' do
      report = Fabricate(:report, account: account, target_account: account, status_ids: [first.id])
      first.discard
      RemovalWorker.new.perform(first.id)

      travel 301.seconds do
        replacement = described_class.new.call(account, original)

        expect(replacement.id).not_to eq first.id
        expect(account.statuses.where(reblog_of_id: original.id).pluck(:id)).to eq [replacement.id]
        expect(original.reload.reblogs_count).to eq 1
        kept = Status.unscoped.find(first.id)
        expect(kept.deleted_at).to be_present
        expect(report.reload.status_ids).to include(first.id)
        expect(report.statuses).to include(kept)
        expect(StatusRelationshipsPresenter.new([original], account.id).reblogs_map[original.id]).to be true
        expect(original.reload.reblogs_count).to eq 1
      end
    end

    it 'does not treat the retained boost as the active one before the next boost' do
      Fabricate(:report, account: account, target_account: account, status_ids: [first.id])
      Fabricate(:notification, account: account, from_account: account, activity: first, type: :reblog)
      first.discard
      RemovalWorker.new.perform(first.id)

      relationships = StatusRelationshipsPresenter.new([original], account.id)
      expect(relationships.reblogs_map[original.id]).to be_nil
      expect(Notification.where(activity: first)).to exist
      expect(Status.reblogs_map([original.id], account.id)).to eq({})
    end

    it 'decrements a retained reported boost only once when another boost stays active' do
      other = Fabricate(:status, reblog: original)
      Fabricate(:report, account: account, target_account: account, status_ids: [first.id])
      first.discard
      RemovalWorker.new.perform(first.id)
      replacement = nil

      travel 301.seconds do
        replacement = described_class.new.call(account, original)
        expect(original.reload.reblogs_count).to eq 2
      end

      replacement.discard
      RemovalWorker.new.perform(replacement.id)

      travel 602.seconds do
        again = described_class.new.call(account, original)

        expect(again.id).not_to eq replacement.id
        expect(account.statuses.where(reblog_of_id: original.id).pluck(:id)).to eq [again.id]
        expect(Status.where(reblog_of_id: original.id).pluck(:id)).to contain_exactly(other.id, again.id)
        expect(original.reload.reblogs_count).to eq 2
        expect(Status.unscoped.find(first.id).deleted_at).to be_present
      end
    end

    it 'does not decrement a retained boost again after redis is cleared or the row is destroyed' do
      other = Fabricate(:status, reblog: original)
      report = Fabricate(:report, account: account, target_account: account, status_ids: [first.id])
      first.discard
      RemovalWorker.new.perform(first.id)

      travel 301.seconds do
        described_class.new.call(account, original)
      end
      expect(original.reload.reblogs_count).to eq 2
      expect(ReboostCountRelease.exists?(status_id: first.id)).to be true

      RedisConfiguration.with do |redis|
        redis.scan_each(match: 'reboost:*') { |key| redis.del(key) }
      end
      expect(Reboost::RetainedCount.release!(original, Status.unscoped.find(first.id))).to be false
      expect(original.reload.reblogs_count).to eq 2

      report.update!(action_taken_at: Time.current)
      Status.unscoped.find(first.id).destroy!
      expect(original.reload.reblogs_count).to eq 2
      expect(Status.where(reblog_of_id: original.id)).to include(other)
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

    it 'returns the wrapper stored while this request waited for the lock' do
      travel 301.seconds do
        replacement = described_class.new.call(account, original, reboost: true, idempotency: 'again')
        service = Reboost::Placement.new(account, original, reboost: true, idempotency: 'again')
        allow(service).to receive(:idempotent_result).and_return(nil, replacement)

        expect(service).not_to receive(:place!)
        expect(service.call).to eq replacement
      end
    end

    it 'keeps the replacement linked when local distribution fails to enqueue' do
      created_id = nil
      allow(DistributionWorker).to receive(:perform_async) do |status_id|
        created_id = status_id
        raise Redis::BaseConnectionError
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true, idempotency: 'again') }.to raise_error(Redis::BaseConnectionError)
        operation = ReboostOperation.order(:id).last
        expect(operation).to have_attributes(state: 'federating', new_status_id: created_id)

        allow(DistributionWorker).to receive(:perform_async)
        retried = described_class.new.call(account, original, reboost: true, idempotency: 'again')

        expect(retried.id).to eq created_id
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
        expect(Reboost::FederationWorker).to have_received(:perform_in).with(Reboost::FEDERATION_GAP, operation.id)
      end
    end

    it 'keeps a second request on the open operation' do
      blocked = true
      allow(Reboost::ResumeWorker).to receive(:perform_in)
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        raise Mastodon::RaceConditionError if blocked

        method.call(*args, **kwargs)
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true, idempotency: 'k1') }.to raise_error(Mastodon::ReboostPendingError)
        operation = ReboostOperation.open.find_by!(account: account, reblog_of: original)

        expect { described_class.new.call(account, original, reboost: true, idempotency: 'k2') }.to raise_error(Mastodon::ReboostPendingError) do |error|
          expect(error.operation.id).to eq operation.id
        end
        expect { described_class.new.call(account, original) }.to raise_error(Mastodon::ReboostPendingError) do |error|
          expect(error.operation.id).to eq operation.id
        end
        expect(ReboostOperation.open.where(account: account, reblog_of: original).count).to eq 1

        blocked = false
        resumed = Reboost::Placement.resume!(operation)

        expect(resumed).to be_present
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
        expect(operation.reload.state).not_to eq 'pending'
      end
    end

    it 'keeps the same pending operation when removal is still locked on the first resume' do
      attempts = 0
      allow(Reboost::ResumeWorker).to receive(:perform_in)
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        attempts += 1
        if attempts < 3
          args.first.discard if args.first.respond_to?(:discard) && args.first.deleted_at.nil?
          raise Mastodon::RaceConditionError
        end

        method.call(*args, **kwargs)
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true, idempotency: 'k1') }.to raise_error(Mastodon::ReboostPendingError)
        operation = ReboostOperation.open.find_by!(account: account, reblog_of: original)

        expect { Reboost::Placement.resume!(operation) }.to raise_error(Mastodon::ReboostPendingError)
        expect(ReboostOperation.where(account: account, reblog_of: original).pluck(:id)).to eq [operation.id]
        expect(operation.reload.state).to eq 'pending'

        resumed = Reboost::Placement.resume!(operation)

        expect(resumed).to be_present
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
        expect(operation.reload.id).to eq operation.id
        expect(operation.state).not_to eq 'pending'
      end
    end

    it 'resumes a pending operation whose worker was never queued' do
      blocked = true
      allow(Reboost::ResumeWorker).to receive(:perform_in)
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        raise Mastodon::RaceConditionError if blocked

        method.call(*args, **kwargs)
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true) }.to raise_error(Mastodon::ReboostPendingError)
        operation = ReboostOperation.open.find_by!(account: account, reblog_of: original)
        operation.update_column(:updated_at, 31.seconds.ago)
        blocked = false

        Scheduler::ReboostDeliveryScheduler.new.perform

        expect(operation.reload.state).not_to eq 'pending'
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
      end
    end

    it 'does not deliver while the old boost is still being removed' do
      started = false
      allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
      allow_any_instance_of(RemoveStatusService).to receive(:call).and_wrap_original do |method, *args, **kwargs|
        unless started
          started = true
          operation = ReboostOperation.find_by!(account: account, reblog_of: original)
          expect(operation).to have_attributes(state: 'pending', new_status_id: nil, removal_finished_at: nil)
          Scheduler::ReboostDeliveryScheduler.new.perform
          Reboost::FederationWorker.new.perform(operation.id)
          expect(ActivityPub::DeliveryWorker).not_to have_received(:push_bulk)
          expect(operation.reload.state).to eq 'pending'
        end
        method.call(*args, **kwargs)
      end

      travel 301.seconds do
        replacement = described_class.new.call(account, original, reboost: true)
        operation = ReboostOperation.find_by!(new_status_id: replacement.id)
        expect(operation.removal_finished_at).to be_present
        expect(operation.state).to eq 'federating'
        expect(Reboost::FederationWorker).to have_received(:perform_in).with(Reboost::FEDERATION_GAP, operation.id)
      end
    end

    it 'retries a notification enqueue that failed after the wrapper was saved' do
      calls = 0
      allow(LocalNotificationWorker).to receive(:perform_async) do
        calls += 1
        raise Redis::BaseConnectionError if calls == 1
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true) }.to raise_error(Redis::BaseConnectionError)
        operation = ReboostOperation.order(:id).last
        expect(operation.notification_enqueued_at).to be_nil
        expect(operation.local_enqueued_at).to be_present

        Scheduler::ReboostDeliveryScheduler.new.perform

        expect(calls).to eq 2
        expect(operation.reload.notification_enqueued_at).to be_present
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
      end
    end

    it 'resumes an unenqueued replacement without the same idempotency key' do
      calls = 0
      allow(Reboost::FederationWorker).to receive(:perform_in) do
        calls += 1
        raise Redis::BaseConnectionError if calls == 1
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true) }.to raise_error(Redis::BaseConnectionError)
        created = account.statuses.find_by(reblog_of_id: original.id)
        operation = ReboostOperation.order(:id).last
        expect(operation).to have_attributes(state: 'federating', new_status_id: created.id, federation_enqueued_at: nil)

        Scheduler::ReboostDeliveryScheduler.new.perform

        expect(calls).to eq 2
        expect(operation.reload.federation_enqueued_at).to be_present
        expect(account.statuses.where(reblog_of_id: original.id).pluck(:id)).to eq [created.id]
      end
    end

    it 'schedules federation on a retry when the first enqueue failed' do
      calls = 0
      allow(Reboost::FederationWorker).to receive(:perform_in) do
        calls += 1
        raise Redis::BaseConnectionError if calls == 1
      end

      travel 301.seconds do
        expect { described_class.new.call(account, original, reboost: true, idempotency: 'again') }.to raise_error(Redis::BaseConnectionError)
        created = account.statuses.find_by(reblog_of_id: original.id)
        retried = described_class.new.call(account, original, reboost: true, idempotency: 'again')

        expect(retried.id).to eq created.id
        expect(calls).to eq 2
        expect(account.statuses.where(reblog_of_id: original.id).count).to eq 1
      end
    end

    it 'delivers a saved Undo when a pending operation can no longer finish' do
      allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
      operation = ReboostOperation.create!(
        account: account,
        reblog_of_id: original.id,
        state: 'pending',
        reboost: true,
        undo_payload: '{"type":"Undo"}',
        undo_inboxes: ['https://remote.example/inbox'],
        options: {}
      )
      refusal = instance_double(StatusPolicy, reblog?: false)
      allow(StatusPolicy).to receive(:new).with(account, original).and_return(refusal)

      expect(Reboost::Placement.resume!(operation)).to be_nil

      expect(operation.reload).to have_attributes(state: 'failed', error_code: 'not_permitted')
      expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://remote.example/inbox'])
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
      allow(ActivityPub::DeliveryWorker).to receive(:push_bulk)
      allow(RedisLock).to receive(:acquire).and_call_original
      expect(RedisLock).to receive(:acquire).with(hash_including(key: "lock:reboost:#{account.id}:#{original.id}")).at_least(:once).and_call_original

      Reboost::Placement.cancel_pending!(account, original.id)

      expect(ActivityPub::DeliveryWorker).to have_received(:push_bulk).with(['https://remote.example/inbox'])
      travel 301.seconds do
        expect(Reboost::Placement.resume!(operation)).to be_nil
      end
      expect(operation.reload).to have_attributes(state: 'cancelled', error_code: 'unreblogged')
      expect(operation.undo_enqueued_at).to be_present
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
