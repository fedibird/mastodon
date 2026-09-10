require 'rails_helper'

# Composed lifecycle on the merged foundation (#26/#28/#29/#30/#31) plus #32.
# Individual PR specs being green does not validate this path.
RSpec.describe 'Moderation ledger composed lifecycle', type: :service do
  def remote_account(username, domain)
    Fabricate(
      :account,
      username: username,
      domain: domain,
      uri: "https://#{domain}/users/#{username}",
      inbox_url: "https://#{domain}/inbox",
      protocol: :activitypub
    )
  end

  it 'preserves linked/correlated, idempotent evidence across import, action, deletion, and retention' do
    ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
      alice     = Fabricate(:account, username: 'alice_lifecycle')
      bob       = remote_account('bob_lifecycle', 'bob.example')
      carol     = Fabricate(:account, username: 'carol_lifecycle')
      moderator = Fabricate(:account, user: Fabricate(:user, admin: true))

      import = instance_double(Import, id: 9_001)
      2.times do
        Moderation::FollowImportRecorder.record_batch(
          account: alice,
          accts: [bob.acct],
          import: import,
          mode: :merge
        )
      end
      expect(FollowImportBatch.where(import_id: import.id).count).to eq 1

      status = Fabricate(:status, account: alice)
      favourite = Fabricate(:favourite, account: alice, status: status)
      2.times do
        Moderation::EventRecorder.record_interaction(
          actor: alice,
          target: bob,
          event_type: :favourite,
          status: status,
          source_record: favourite
        )
      end
      expect(ModerationInteractionEvent.where(source_event_key: "Favourite:#{favourite.id}:favourite").count).to eq 1

      contact = Moderation::EventRecorder.record_interaction(actor: alice, target: bob, event_type: :follow)
      rejection = Moderation::EventRecorder.record_rejection(rejector: bob, rejected: alice, event_type: :block)
      expect(rejection.preceding_interaction_event).to eq contact

      Moderation::EventRecorder.record_rejection(rejector: carol, rejected: alice, event_type: :block, occurred_at: 3.hours.ago)
      Moderation::EventRecorder.record_interaction(actor: alice, target: carol, event_type: :mention, occurred_at: 1.hour.ago)

      action = Admin::AccountAction.new
      action.assign_attributes(type: 'silence', current_account: moderator, target_account: alice)
      action.save!

      snapshot = ModerationAction.last.evidence_snapshot
      bob_subject = contact.target_subject
      carol_subject = ModerationSubject.find_by(account_id: carol.id)
      alice_subject = contact.actor_subject

      expect(snapshot.linked_negative_target_subject_ids).to include(bob_subject.id)
      expect(snapshot.linked_negative_target_subject_ids).to_not include(carol_subject.id)
      expect(snapshot.correlated_negative_target_subject_ids).to include(carol_subject.id)
      expect(snapshot.fingerprint.dig('coverage', 'inbound_activitypub')).to eq 'partial'
      expect(snapshot.fingerprint.dig('coverage', 'complete_for_remote_subjects')).to be false
      expect(snapshot.fingerprint.dig('coverage', 'observed_inbound_event_types')).to include('follow_reject')
      expect(snapshot.fingerprint.dig('coverage', 'known_inbound_recording_gaps'))
        .to include(a_hash_including('event_type' => 'follow_reject', 'repairable' => false))

      expect { status.destroy! }.to_not change(ModerationInteractionEvent, :count)
      expect(ModerationInteractionEvent.exists?(contact.id)).to be true

      expect { DeleteAccountService.new.call(bob, reserve_username: false, skip_side_effects: true) }
        .to_not change(ModerationInteractionEvent, :count)

      bob_subject.reload.tombstone!(now: 40.days.ago)
      Scheduler::ModerationLedgerRetentionScheduler.new.perform

      expect(ModerationSubject.exists?(alice_subject.id)).to be true
      expect(ModerationInteractionEvent.exists?(contact.id)).to be true
      expect(ModerationRejectionEvent.exists?(rejection.id)).to be true
      expect(ModerationInteractionEvent.where(actor_subject_id: alice_subject.id)).to exist
      expect(ModerationRejectionEvent.where(rejected_subject_id: alice_subject.id)).to exist
      expect(ModerationEvidenceSnapshot.exists?(snapshot.id)).to be true
    end
  end

  it 'keeps evidence after a counterpart subject id is nullified while the other participant is retained' do
    ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
      alice = Fabricate(:account, username: 'alice_null_counterpart')
      bob   = Fabricate(:account, username: 'bob_null_counterpart')

      contact = Moderation::EventRecorder.record_interaction(actor: alice, target: bob, event_type: :follow)
      rejection = Moderation::EventRecorder.record_rejection(rejector: bob, rejected: alice, event_type: :block)
      alice_subject = contact.actor_subject
      bob_subject   = contact.target_subject

      contact.update_columns(target_subject_id: nil)
      rejection.update_columns(rejector_subject_id: nil)
      bob_subject.update!(deleted_at: 40.days.ago, retention_until: 10.days.ago)

      Scheduler::ModerationLedgerRetentionScheduler.new.perform

      expect(ModerationSubject.exists?(alice_subject.id)).to be true
      expect(ModerationInteractionEvent.exists?(contact.id)).to be true
      expect(ModerationRejectionEvent.exists?(rejection.id)).to be true
      expect(ModerationSubject.exists?(bob_subject.id)).to be false

      snapshot = Moderation::EvidenceSnapshotService.new.call(alice)
      expect(snapshot.linked_negative_target_subject_ids).to be_empty
      expect(snapshot.fingerprint['linked_negative_target_subject_ids']).to_not include(nil)
      expect(snapshot.summary['unique_contacts']).to eq 0
    end
  end

  it 'deletes events once every remaining participant is expired or null' do
    ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
      expired_a = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)
      expired_b = Fabricate(:moderation_subject, deleted_at: 40.days.ago, retention_until: 10.days.ago)
      both_expired = Fabricate(:moderation_interaction_event, actor_subject: expired_a, target_subject: expired_b)
      all_null = Fabricate(:moderation_interaction_event, actor_subject: expired_a, target_subject: expired_b)
      all_null.update_columns(actor_subject_id: nil, target_subject_id: nil)

      Scheduler::ModerationLedgerRetentionScheduler.new.perform

      expect(ModerationInteractionEvent.exists?(both_expired.id)).to be false
      expect(ModerationInteractionEvent.exists?(all_null.id)).to be false
      expect(ModerationSubject.exists?(expired_a.id)).to be false
      expect(ModerationSubject.exists?(expired_b.id)).to be false
    end
  end
end
