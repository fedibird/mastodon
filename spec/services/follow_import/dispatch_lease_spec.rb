# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe FollowImport::DispatchLease do # rubocop:disable Metrics/BlockLength
  def lease_row
    FollowImportDispatchLease.find(FollowImportDispatchLease::SINGLETON_ID)
  end

  def restore_lease_row!
    row = FollowImportDispatchLease.find_or_initialize_by(id: FollowImportDispatchLease::SINGLETON_ID)
    row.fencing_generation = 0 if row.new_record?
    row.owner_token = nil
    row.expires_at = nil
    row.save!
  end

  def dispatcher_advisory_lock_count(objsubid: 2)
    sql = <<~SQL.squish
      SELECT COUNT(*)
      FROM pg_locks
      WHERE locktype = 'advisory'
        AND classid = #{described_class::LOCK_NAMESPACE}
        AND objid = #{described_class::LOCK_KEY}
        AND objsubid = #{objsubid}
        AND granted
    SQL
    ActiveRecord::Base.connection.select_value(sql).to_i
  end

  def boolean_result(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  def with_extra_connection
    pool = ActiveRecord::Base.connection_pool
    pool.lock_thread = false
    conn = pool.checkout
    yield conn
  ensure
    if conn
      conn.rollback_db_transaction if conn.transaction_open?
      conn.disconnect!
      pool.remove(conn)
    end
    ActiveRecord::Base.connection_pool.lock_thread = true
  end

  after do
    restore_lease_row!
  end

  describe 'lock identity' do
    it 'uses a documented two-integer xact key and no session advisory SQL' do
      source = File.read(Rails.root.join('app/services/follow_import/dispatch_lease.rb'))

      expect(described_class::LOCK_NAMESPACE).to eq 0x4649
      expect(described_class::LOCK_KEY).to eq 1
      expect(described_class::STRATEGY).to eq 'durable_row_v1'
      expect(described_class::TRY_XACT_LOCK_SQL).to eq "SELECT pg_try_advisory_xact_lock(#{described_class::LOCK_NAMESPACE}, #{described_class::LOCK_KEY})"
      expect(source).to include('pg_try_advisory_xact_lock')
      expect(source).not_to match(/pg_try_advisory_lock(?!_xact)/)
      expect(source).not_to include('pg_advisory_unlock')
      expect(source).not_to include('pg_advisory_unlock_all')
      expect(source).not_to include('pg_backend_pid')
      expect(source).not_to include('CURRENT_SESSION_LOCK_SQL')
      expect(source).not_to include('MAX_STALE_LOCK_DEPTH')
      expect(dispatcher_advisory_lock_count(objsubid: 1)).to eq 0
    end
  end

  describe 'durable row acquisition' do # rubocop:disable Metrics/BlockLength
    it 'yields exactly once on uncontended acquisition and releases afterward' do
      yielded = 0
      handle_during = nil

      result = described_class.with_lease do |handle|
        yielded += 1
        handle_during = handle
        expect(handle.strategy).to eq described_class::STRATEGY
        expect(handle.current_owner?).to be true
        expect(lease_row.owner_token).to eq handle.owner_token
        expect(dispatcher_advisory_lock_count(objsubid: 1)).to eq 0
        :body
      end

      expect(yielded).to eq 1
      expect(result).to eq :body
      expect(handle_during.current_owner?).to be false
      expect(lease_row.owner_token).to be_nil
      expect(lease_row.expires_at).to be_nil
      expect(dispatcher_advisory_lock_count(objsubid: 1)).to eq 0
    end

    it 'returns busy and does not yield when the durable row is already held' do
      described_class.with_lease do |outer|
        yielded = false
        result = described_class.with_lease do
          yielded = true
          outer
        end

        expect(yielded).to be false
        expect(result).to eq described_class::BUSY
        expect(outer.current_owner?).to be true
        :held
      end

      expect(lease_row.owner_token).to be_nil
    end

    it 'releases ownership when the body raises' do
      expect { described_class.with_lease { raise StandardError, 'tick exploded' } }
        .to raise_error(StandardError, 'tick exploded')

      expect(lease_row.owner_token).to be_nil
      expect(lease_row.expires_at).to be_nil
      expect(dispatcher_advisory_lock_count(objsubid: 1)).to eq 0
    end

    it 'fails closed when acquisition setup raises' do
      allow_any_instance_of(described_class).to receive(:try_xact_lock?).and_raise(StandardError, 'lock query failed')

      yielded = false
      result = described_class.with_lease { yielded = true }

      expect(yielded).to be false
      expect(result).to eq described_class::BUSY
      expect(lease_row.owner_token).to be_nil
    end

    it 'fails closed when the singleton lease row is missing' do
      FollowImportDispatchLease.delete_all

      yielded = false
      result = described_class.with_lease { yielded = true }

      expect(yielded).to be false
      expect(result).to eq described_class::BUSY
    end

    it 'does not let a non-owner token clear a newer generation' do
      lease_row.update!(
        owner_token: 'owner-a',
        fencing_generation: 9,
        expires_at: 1.hour.from_now
      )

      described_class.new.send(
        :release,
        described_class::Handle.new(owner_token: 'owner-b', fencing_generation: 9, strategy: described_class::STRATEGY)
      )

      expect(lease_row.reload.owner_token).to eq 'owner-a'
      expect(lease_row.fencing_generation).to eq 9
    end

    it 'recovers an expired crashed owner with a new fencing generation' do
      lease_row.update!(
        owner_token: 'stale',
        fencing_generation: 4,
        expires_at: 1.hour.ago
      )

      handle = nil
      described_class.with_lease do |acquired|
        handle = acquired
        expect(acquired.fencing_generation).to eq 5
        expect(acquired.owner_token).not_to eq 'stale'
        expect(acquired.current_owner?).to be true
      end

      expect(handle.current_owner?).to be false
      expect(lease_row.reload.owner_token).to be_nil
      expect(lease_row.fencing_generation).to eq 5
    end

    it 'does not treat an older fencing generation as current after a newer owner takes over' do
      stale = nil
      described_class.with_lease do |handle|
        stale = handle
        lease_row.update!(
          owner_token: 'newer',
          fencing_generation: handle.fencing_generation + 1,
          expires_at: 1.hour.from_now
        )
        expect(handle.current_owner?).to be false
        :stale
      end

      expect(lease_row.reload.owner_token).to eq 'newer'
      expect(stale.current_owner?).to be false
    end

    it 'does not treat an expired matching token as current ownership' do
      described_class.with_lease do |handle|
        lease_row.update!(expires_at: 1.hour.ago)
        expect(handle.current_owner?).to be false
      end
    end
  end

  describe 'transaction-scoped advisory lock' do
    self.use_transactional_tests = false

    it 'holds the xact lock only for the explicit transaction and releases on rollback' do
      with_extra_connection do |extra|
        extra.transaction do
          expect(boolean_result(extra.select_value(described_class::TRY_XACT_LOCK_SQL))).to be true
          expect(dispatcher_advisory_lock_count).to eq 1
          expect(described_class.with_lease { :should_not_run }).to eq described_class::BUSY
          raise ActiveRecord::Rollback
        end

        expect(dispatcher_advisory_lock_count).to eq 0
        expect(described_class.with_lease { :ok }).to eq :ok
      end
    end

    it 'releases the xact lock when the holding transaction commits' do
      with_extra_connection do |holder|
        holder.transaction do
          expect(boolean_result(holder.select_value(described_class::TRY_XACT_LOCK_SQL))).to be true
          expect(dispatcher_advisory_lock_count).to eq 1
        end

        expect(dispatcher_advisory_lock_count).to eq 0

        with_extra_connection do |verifier|
          verifier.transaction do
            expect(boolean_result(verifier.select_value(described_class::TRY_XACT_LOCK_SQL))).to be true
            expect(dispatcher_advisory_lock_count).to eq 1
          end
        end

        expect(dispatcher_advisory_lock_count).to eq 0
      end
    end

    it 'does not hold the xact lock while the leased body runs' do
      described_class.with_lease do |handle|
        expect(handle.current_owner?).to be true
        expect(dispatcher_advisory_lock_count).to eq 0

        with_extra_connection do |extra|
          extra.transaction do
            expect(boolean_result(extra.select_value(described_class::TRY_XACT_LOCK_SQL))).to be true
          end
        end
      end

      expect(dispatcher_advisory_lock_count).to eq 0
    end
  end

  describe 'process exclusion' do
    self.use_transactional_tests = false

    it 'does not allow two threads to enter the critical section' do
      pool = ActiveRecord::Base.connection_pool
      pool.lock_thread = false

      ready = Queue.new
      release = Queue.new
      second_status = Queue.new
      holder = nil
      waiter = nil

      holder = Thread.new do
        described_class.with_lease do
          ready << true
          release.pop
          :held
        end
      end

      Timeout.timeout(5) do
        ready.pop
        waiter = Thread.new do
          second_status << described_class.with_lease { :should_not_run }
        end
        expect(second_status.pop).to eq described_class::BUSY
      end
    ensure
      release << true if release
      holder&.join(2)
      waiter&.join(2)
      ActiveRecord::Base.connection_pool.lock_thread = true
    end

    it 'does not mutate Follow Import rows while the lease is held' do
      batch = FollowImportBatch.create!(
        subject: Fabricate(:moderation_subject),
        imported_at: Time.now.utc,
        mode: :merge,
        target_count: 0,
        resolved_target_count: 0,
        unresolved_target_count: 0
      )
      target = batch.targets.create!(target_key_hash: 'lease-spec', position: 0)

      described_class.with_lease do
        expect(target.reload.state).to eq 'pending'
      end

      expect(described_class.with_lease { :inside }).to eq :inside
      expect(target.reload.state).to eq 'pending'
    ensure
      target&.destroy
      batch&.destroy
    end
  end
end
