require 'rails_helper'

RSpec.describe ModerationSubject, type: :model do
  describe 'validations' do
    it 'is valid with the required attributes' do
      expect(Fabricate.build(:moderation_subject)).to be_valid
    end

    it 'requires first_seen_at and last_seen_at' do
      subject = Fabricate.build(:moderation_subject, first_seen_at: nil, last_seen_at: nil)
      expect(subject).to_not be_valid
      expect(subject.errors.attribute_names).to include(:first_seen_at, :last_seen_at)
    end
  end

  describe '.for_account!' do
    let(:account) { Fabricate(:account, domain: nil) }

    it 'creates a subject linked to the account with derived origin/domain' do
      expect { ModerationSubject.for_account!(account) }.to change(ModerationSubject, :count).by(1)

      subject = ModerationSubject.find_by(account_id: account.id)
      expect(subject.origin).to eq 'local'
      expect(subject.domain).to be_nil
      expect(subject.first_seen_at).to be_present
      expect(subject.last_seen_at).to be_present
    end

    it 'is idempotent for the same account and refreshes last_seen_at' do
      first = ModerationSubject.for_account!(account, observed_at: 1.hour.ago)
      second = nil

      expect { second = ModerationSubject.for_account!(account, observed_at: Time.now.utc) }.to_not change(ModerationSubject, :count)
      expect(second.id).to eq first.id
      expect(second.reload.last_seen_at).to be > first.first_seen_at
    end

    it 'marks remote accounts as remote origin' do
      remote = Fabricate(:account, domain: 'remote.example', uri: 'https://remote.example/users/bob')
      subject = ModerationSubject.for_account!(remote)
      expect(subject.origin).to eq 'remote'
      expect(subject.domain).to eq 'remote.example'
    end

    it 'returns the argument unchanged when already a ModerationSubject' do
      existing = Fabricate(:moderation_subject)
      expect(ModerationSubject.for_account!(existing)).to eq existing
    end
  end

  describe '#tombstone!' do
    it 'sets deleted_at without destroying the row' do
      subject = Fabricate(:moderation_subject)
      subject.tombstone!
      expect(subject.reload).to be_tombstoned
      expect(ModerationSubject.exists?(subject.id)).to be true
    end
  end
end
