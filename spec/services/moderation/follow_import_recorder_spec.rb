require 'rails_helper'

RSpec.describe Moderation::FollowImportRecorder, type: :service do
  let(:account) { Fabricate(:account, username: 'importer') }
  let!(:bob)    { Fabricate(:account, username: 'bob') }
  let!(:eve)    { Fabricate(:account, username: 'eve', domain: 'example.com') }

  describe '.record_batch' do
    it 'records a batch with resolved and unresolved targets' do
      accts = ['bob', 'eve@example.com', 'ghost@unknown.example']

      batch = nil
      expect { batch = described_class.record_batch(account: account, accts: accts, mode: :merge) }
        .to change(FollowImportBatch, :count).by(1)
        .and change(FollowImportTarget, :count).by(3)

      expect(batch.subject.account_id).to eq account.id
      expect(batch.mode).to eq 'merge'
      expect(batch.target_count).to eq 3
      expect(batch.resolved_target_count).to eq 2
      expect(batch.unresolved_target_count).to eq 1
      expect(batch.account_age_seconds).to be_present

      resolved = batch.targets.where.not(target_subject_id: nil)
      expect(resolved.map { |t| t.target_subject.account_id }).to match_array([bob.id, eve.id])

      unresolved = batch.targets.find_by(target_subject_id: nil)
      expect(unresolved.target_key_hash).to eq Digest::SHA256.hexdigest('ghost@unknown.example')
      expect(unresolved.position).to eq 2
    end

    it 'records prior following relationship state for resolved targets' do
      account.follow!(bob)

      batch = described_class.record_batch(account: account, accts: ['bob'], mode: :overwrite)

      expect(batch.mode).to eq 'overwrite'
      expect(batch.targets.first.prior_relationship_state).to eq('following' => true)
    end

    it 'defaults mode to unknown' do
      batch = described_class.record_batch(account: account, accts: ['bob'])
      expect(batch.mode).to eq 'unknown'
    end

    it 'marks migration evidence weak when the account has aliases' do
      # Insert directly to avoid AccountAlias#set_uri resolving over the network.
      AccountAlias.insert!({ account_id: account.id, acct: 'old@example.com', uri: 'https://example.com/users/old', created_at: Time.now.utc, updated_at: Time.now.utc })

      batch = described_class.record_batch(account: account, accts: [])
      expect(batch.migration_evidence).to eq 'weak'
    end

    it 'is failure-tolerant and returns nil on error' do
      allow(Rails.logger).to receive(:warn)
      expect(described_class.record_batch(account: nil, accts: ['bob'])).to be_nil
    end
  end
end
