require 'rails_helper'

RSpec.describe 'ModerationSubject retention', type: :model do
  describe '#tombstone!' do
    it 'sets deleted_at and retention_until from the policy' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '30' do
        subject = Fabricate(:moderation_subject)
        now = Time.now.utc

        subject.tombstone!(now: now)

        expect(subject.reload).to be_tombstoned
        expect(subject.deleted_at).to be_within(1.second).of(now)
        expect(subject.retention_until).to be_within(1.second).of(now + 30.days)
      end
    end

    it 'leaves retention_until nil when retention is disabled' do
      ClimateControl.modify MODERATION_LEDGER_RETENTION_DAYS: '0' do
        subject = Fabricate(:moderation_subject)

        subject.tombstone!

        expect(subject.reload).to be_tombstoned
        expect(subject.retention_until).to be_nil
      end
    end
  end

  describe '.tombstone_for_account!' do
    it 'tombstones the live subject bound to the account' do
      account = Fabricate(:account)
      subject = ModerationSubject.for_account!(account)

      ModerationSubject.tombstone_for_account!(account)

      expect(subject.reload).to be_tombstoned
    end
  end

  describe 'scopes' do
    it 'orphaned matches detached, non-tombstoned subjects' do
      subject = Fabricate(:moderation_subject)
      subject.update!(account_id: nil)

      expect(ModerationSubject.orphaned).to include(subject)
    end

    it 'expired matches tombstoned subjects past retention_until' do
      expired = Fabricate(:moderation_subject, deleted_at: 2.days.ago, retention_until: 1.day.ago)
      future  = Fabricate(:moderation_subject, deleted_at: 2.days.ago, retention_until: 1.day.from_now)

      expect(ModerationSubject.expired).to include(expired)
      expect(ModerationSubject.expired).to_not include(future)
    end

    it 'retained matches live subjects and tombstones that have not reached eligibility' do
      live    = Fabricate(:moderation_subject)
      future  = Fabricate(:moderation_subject, deleted_at: 2.days.ago, retention_until: 1.day.from_now)
      expired = Fabricate(:moderation_subject, deleted_at: 2.days.ago, retention_until: 1.day.ago)

      expect(ModerationSubject.retained).to include(live, future)
      expect(ModerationSubject.retained).to_not include(expired)
    end
  end
end
