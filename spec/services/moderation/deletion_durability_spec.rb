require 'rails_helper'

# PR 3: deleting/purging an account through DeleteAccountService must tombstone
# the moderation subject (and set its retention window) while preserving the
# recorded events — the account link is only nullified, never cascaded.
RSpec.describe 'Moderation ledger deletion durability', type: :service do
  it 'tombstones the subject and preserves events when an account is purged' do
    ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
      actor  = Fabricate(:account, domain: 'a.example', uri: 'https://a.example/users/x', inbox_url: 'https://a.example/inbox', protocol: :activitypub)
      target = Fabricate(:account, domain: 'b.example', uri: 'https://b.example/users/y', inbox_url: 'https://b.example/inbox', protocol: :activitypub)

      event = Moderation::EventRecorder.record_interaction(actor: actor, target: target, event_type: :follow)
      subject_id = event.actor_subject_id

      expect { DeleteAccountService.new.call(actor, reserve_username: false, skip_side_effects: true) }
        .to_not change(ModerationInteractionEvent, :count)

      subject = ModerationSubject.find(subject_id)
      expect(subject.account_id).to be_nil
      expect(subject).to be_tombstoned
      expect(subject.retention_until).to be_present
      expect(ModerationInteractionEvent.exists?(event.id)).to be true
    end
  end
end
