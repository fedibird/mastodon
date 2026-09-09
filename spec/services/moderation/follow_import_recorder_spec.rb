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

    it 'does not create a second batch when the same import is retried' do
      import = instance_double(Import, id: 880_001)

      first = described_class.record_batch(account: account, accts: ['bob', 'eve@example.com'], import: import, mode: :merge)
      second = described_class.record_batch(account: account, accts: ['ghost@unknown.example'], import: import, mode: :overwrite)

      expect(FollowImportBatch.where(import_id: import.id).count).to eq 1
      expect(second.id).to eq first.id
      expect(second.mode).to eq 'merge'
      expect(FollowImportTarget.where(batch_id: first.id).count).to eq 2
    end

    it 'rejects a second row with the same import_id at the database' do
      import = instance_double(Import, id: 880_003)
      first = described_class.record_batch(account: account, accts: ['bob'], import: import)

      expect {
        FollowImportBatch.insert!({
          subject_id: first.subject_id,
          import_id: import.id,
          imported_at: Time.now.utc,
          mode: 0,
          target_count: 0,
          resolved_target_count: 0,
          unresolved_target_count: 0,
          migration_evidence: 0,
          metadata: {},
          created_at: Time.now.utc,
          updated_at: Time.now.utc,
        })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'returns the existing batch when a uniqueness race loses the insert' do
      import = instance_double(Import, id: 880_002)
      first = described_class.record_batch(account: account, accts: ['bob'], import: import)
      lookups = 0

      # Simulate the race window: the pre-insert lookup misses the committed row.
      allow(FollowImportBatch).to receive(:find_by).and_wrap_original do |method, *args|
        attrs = args.first
        if attrs.is_a?(Hash) && attrs[:import_id] == import.id
          lookups += 1
          lookups == 1 ? nil : method.call(*args)
        else
          method.call(*args)
        end
      end

      # Sequential specs see the committed row in the uniqueness validator; a
      # real race under READ COMMITTED would not. Skip validations so the
      # INSERT hits the unique index on import_id.
      allow_any_instance_of(FollowImportBatch).to receive(:valid?).and_return(true)
      expect(FollowImportBatch).to receive(:create!).and_call_original

      raced = described_class.new.record_batch(account: account, accts: ['bob'], import: import)

      expect(raced.id).to eq first.id
      expect(FollowImportBatch.where(import_id: import.id).count).to eq 1
      expect(lookups).to be >= 1
    end
  end
end
