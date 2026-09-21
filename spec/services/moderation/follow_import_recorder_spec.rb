# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Moderation::FollowImportRecorder, type: :service do # rubocop:disable Metrics/BlockLength
  let(:account) { Fabricate(:account, username: 'importer') }
  let!(:bob)    { Fabricate(:account, username: 'bob') }
  let!(:eve)    { Fabricate(:account, username: 'eve', domain: 'example.com') }

  describe '.record_batch' do # rubocop:disable Metrics/BlockLength
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

    it 'stores a normalized destination_domain without the username' do
      local_domain = TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
      batch = described_class.record_batch(
        account: account,
        accts: ['eve@EXAMPLE.COM', 'bob', "bob@#{Rails.configuration.x.local_domain}", 'ghost@Unknown.example']
      )

      by_hash = batch.targets.index_by(&:target_key_hash)
      expect(by_hash[FollowImportTarget.key_hash('eve@example.com')].destination_domain).to eq 'example.com'
      expect(by_hash[FollowImportTarget.key_hash('bob')].destination_domain).to eq local_domain
      expect(by_hash[FollowImportTarget.key_hash('ghost@unknown.example')].destination_domain).to eq 'unknown.example'
    end

    it 'keeps destination_domain on unresolved targets and preserves CSV position' do
      batch = described_class.record_batch(account: account, accts: ['ghost@unknown.example', 'bob'])

      unresolved = batch.targets.find_by(target_subject_id: nil)
      expect(unresolved.destination_domain).to eq 'unknown.example'
      expect(unresolved.position).to eq 0
      expect(batch.targets.find_by(position: 1).destination_domain).to eq(
        TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
      )
    end

    it 'stores the canonical key hash on resolved targets as the correlation key' do
      batch  = described_class.record_batch(account: account, accts: ['bob'], mode: :merge)
      target = batch.targets.first

      expect(target.target_subject.account_id).to eq bob.id
      expect(target.target_key_hash).to eq FollowImportTarget.key_hash('bob')
    end

    it 'deduplicates repeated addresses into one target per execution unit' do
      local_bob = "bob@#{Rails.configuration.x.local_domain}"
      accts     = ['bob', 'bob', local_bob, 'eve@example.com', 'eve@example.com', 'ghost@unknown.example']

      batch = nil
      expect { batch = described_class.record_batch(account: account, accts: accts, mode: :merge) }
        .to change(FollowImportTarget, :count).by(3)

      expect(batch.target_count).to eq 3
      expect(batch.resolved_target_count).to eq 2
      expect(batch.unresolved_target_count).to eq 1
      expect(batch.targets.map(&:target_key_hash)).to match_array(
        [FollowImportTarget.key_hash('bob'), FollowImportTarget.key_hash('eve@example.com'), FollowImportTarget.key_hash('ghost@unknown.example')]
      )
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

    it 'defaults a new batch to legacy dispatch ownership' do
      batch = described_class.record_batch(account: account, accts: ['bob'])
      expect(batch.legacy_dispatch_owner?).to be true
    end

    it 'explicitly records a new batch in the operational dispatch cohort' do
      batch = described_class.record_batch(account: account, accts: ['bob'])
      expect(batch.operational_dispatch_cohort?).to be true
      expect(batch.historical_dispatch_cohort?).to be false
    end

    it 'records a new operational batch as screening before any release' do
      batch = described_class.record_batch(account: account, accts: ['bob'])
      expect(batch.screening_preflight_state?).to be true
      expect(batch.ready_preflight_state?).to be false
    end

    it 'persists an explicit scheduler owner only for a newly created batch' do
      batch = described_class.record_batch(account: account, accts: ['bob'], dispatch_owner: :scheduler)
      expect(batch.scheduler_dispatch_owner?).to be true
      expect(batch.operational_dispatch_cohort?).to be true
    end

    it 'does not rewrite stored ownership when the same import is retried' do
      import = instance_double(Import, id: 880_010)
      first = described_class.record_batch(account: account, accts: ['bob'], import: import, dispatch_owner: :legacy)
      second = described_class.record_batch!(account: account, accts: ['eve@example.com'], import: import, dispatch_owner: :scheduler)

      expect(second.id).to eq first.id
      expect(second.legacy_dispatch_owner?).to be true
      expect(second.scheduler_dispatch_owner?).to be false
      expect(second.operational_dispatch_cohort?).to be true
      expect(second.screening_preflight_state?).to be true
    end

    it 'does not convert review_required or stopped back to screening or ready on retry' do
      import = instance_double(Import, id: 880_015)
      held = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(account),
        import_id: import.id,
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_owner: :legacy,
        dispatch_cohort: :operational,
        preflight_state: :review_required,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0
      )

      retried = described_class.record_batch!(account: account, accts: ['bob'], import: import)

      expect(retried.id).to eq held.id
      expect(retried.review_required_preflight_state?).to be true
      expect(FollowImportTarget.where(batch_id: held.id).count).to eq 0
    end

    it 'does not promote a historical batch when the same import is retried' do
      import = instance_double(Import, id: 880_013)
      historical = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(account),
        import_id: import.id,
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_owner: :legacy,
        dispatch_cohort: :historical,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0
      )

      retried = described_class.record_batch!(account: account, accts: ['bob'], import: import, dispatch_owner: :scheduler)

      expect(retried.id).to eq historical.id
      expect(retried.historical_dispatch_cohort?).to be true
      expect(retried.legacy_dispatch_owner?).to be true
      expect(FollowImportTarget.where(batch_id: historical.id).count).to eq 0
    end

    it 'preserves an operational batch cohort when the same import is retried' do
      import = instance_double(Import, id: 880_014)
      first = described_class.record_batch(account: account, accts: ['bob'], import: import, dispatch_owner: :legacy)
      second = described_class.record_batch(account: account, accts: ['eve@example.com'], import: import)

      expect(second.id).to eq first.id
      expect(second.operational_dispatch_cohort?).to be true
      expect(second.legacy_dispatch_owner?).to be true
    end

    it 'preserves a scheduler-owned batch when a later retry asks for legacy' do
      import = instance_double(Import, id: 880_011)
      first = described_class.record_batch!(account: account, accts: ['bob'], import: import, dispatch_owner: :scheduler)
      second = described_class.record_batch(account: account, accts: ['eve@example.com'], import: import, dispatch_owner: :legacy)

      expect(second.id).to eq first.id
      expect(second.scheduler_dispatch_owner?).to be true
      expect(second.operational_dispatch_cohort?).to be true
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

      expect do
        FollowImportBatch.insert!(
          {
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
          }
        )
      end.to raise_error(ActiveRecord::RecordNotUnique)
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
      expect(raced.operational_dispatch_cohort?).to be true
      expect(raced.legacy_dispatch_owner?).to be true
      expect(FollowImportBatch.where(import_id: import.id).count).to eq 1
      expect(lookups).to be >= 1
    end

    it 'returns a committed historical row unchanged after a uniqueness race' do
      import = instance_double(Import, id: 880_015)
      first = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(account),
        import_id: import.id,
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_owner: :legacy,
        dispatch_cohort: :historical,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0
      )
      lookups = 0

      allow(FollowImportBatch).to receive(:find_by).and_wrap_original do |method, *args|
        attrs = args.first
        if attrs.is_a?(Hash) && attrs[:import_id] == import.id
          lookups += 1
          lookups == 1 ? nil : method.call(*args)
        else
          method.call(*args)
        end
      end

      allow_any_instance_of(FollowImportBatch).to receive(:valid?).and_return(true)

      raced = described_class.new.record_batch(account: account, accts: ['bob'], import: import, dispatch_owner: :scheduler)

      expect(raced.id).to eq first.id
      expect(raced.historical_dispatch_cohort?).to be true
      expect(raced.legacy_dispatch_owner?).to be true
      expect(FollowImportBatch.where(import_id: import.id).count).to eq 1
    end
  end

  describe '.record_batch!' do
    it 'raises on persistence failure instead of returning nil' do
      expect { described_class.record_batch!(account: nil, accts: ['bob']) }.to raise_error(StandardError)
    end

    it 'shares import_id idempotency with the tolerant API' do
      import = instance_double(Import, id: 880_012)
      first = described_class.record_batch!(account: account, accts: ['bob'], import: import, dispatch_owner: :scheduler)
      second = described_class.record_batch!(account: account, accts: ['eve@example.com'], import: import, dispatch_owner: :legacy)

      expect(second.id).to eq first.id
      expect(second.scheduler_dispatch_owner?).to be true
      expect(second.operational_dispatch_cohort?).to be true
      expect(FollowImportTarget.where(batch_id: first.id).count).to eq 1
    end
  end
end
