# frozen_string_literal: true

module GroupInitialFollows
  # Runs the one-time follow for a founding owner.
  #
  # Boundaries:
  # 1. The approval transaction inserts this row as pending and does not
  #    insert a Follow. The worker is enqueued after that commit.
  # 2. A short transaction claims the row (processing) so a crash is visible.
  # 3. FollowService creates the Follow or FollowRequest. The discharge
  #    timestamp, outcome, and relationship id commit in that same
  #    transaction. A crash before commit rolls both back, so the person
  #    cannot unfollow a follow they never saw.
  # 4. The terminal state (succeeded or completed) commits after that. A
  #    crash in between leaves the discharge timestamp set. Resume finalizes
  #    the marker and does not create another follow, even if the person
  #    already unfollowed.
  # 5. An existing relationship is completed without calling FollowService,
  #    so options and delivery are left alone.
  # 6. Delivery, notifications, and feed merge stay inside FollowService.
  #    They are not reimplemented here. Locked, silenced, blocked, and
  #    suspended accounts keep those rules.
  class Perform
    class Crash < StandardError; end

    def self.call(record, crash_after: nil)
      new(record, crash_after).call
    end

    def initialize(record, crash_after)
      @record = record
      @crash_after = crash_after
      @locked = false
    end

    def call
      @record.class.connection_pool.with_connection do
        return unless take_lock!

        begin
          execute
        ensure
          release_lock!
        end
      end
    end

    private

    def execute
      @record.reload
      return if @record.terminal?

      claim! unless @record.discharged?
      return if @record.terminal?
      return finalize! if @record.discharged?

      refusal = refusal_code
      return mark_permanent!(refusal) if refusal

      existing = existing_relationship
      return mark_existing!(existing) if existing

      create_and_latch!
      finalize! if @record.reload.discharged?
    rescue Crash
      raise
    rescue Mastodon::NotPermittedError
      mark_permanent!(:not_permitted) unless fresh_discharged?
    rescue ActiveRecord::RecordNotFound
      mark_permanent!(:not_possible) unless fresh_discharged?
    rescue Mastodon::RateLimitExceededError
      mark_failure!(:rate_limited) unless fresh_discharged?
    rescue ActiveRecord::RecordInvalid
      mark_failure!(:invalid_follow) unless fresh_discharged?
      raise
    rescue StandardError => e
      mark_failure!(error_code(e)) unless fresh_discharged?
      raise
    end

    def claim!
      @record.with_lock do
        @record.reload
        unless @record.terminal? || @record.discharged?
          @record.update!(
            state: :processing,
            claim_expires_at: GroupInitialFollow::LEASE.from_now,
            attempts: @record.attempts + 1,
            last_error: nil
          )
        end
      end
    end

    # requires_new so a crash after the follow insert rolls that insert back
    # even when a test or caller already has a transaction open. The claim
    # above stays in place. The discharge columns are written before this
    # savepoint commits, so they are not visible without the follow.
    def create_and_latch!
      latched = false
      ApplicationRecord.transaction(requires_new: true) do
        @record.lock!
        @record.reload
        next if @record.terminal? || @record.discharged?

        if (existing = existing_relationship)
          mark_existing!(existing)
          next
        end

        if (refusal = refusal_code)
          mark_permanent!(refusal)
          next
        end

        relationship = FollowService.new.call(owner, group, with_rate_limit: true)
        raise Crash, 'after_relationship_insert' if @crash_after == :after_relationship_insert

        if relationship.nil?
          mark_failure!(:empty_relationship)
          next
        end

        @record.update!(latch_attributes(relationship).merge(state: :processing, claim_expires_at: GroupInitialFollow::LEASE.from_now))
        latched = true
      end
      raise Crash, 'after_latch_commit' if latched && @crash_after == :after_latch_commit
    end

    def finalize!
      @record.with_lock do
        @record.reload
        if !@record.terminal? && @record.discharged?
          state = @record.outcome.to_s.start_with?('existing_') ? :completed : :succeeded
          @record.update!(state: state, finished_at: Time.current, claim_expires_at: nil, last_error: nil)
        end
      end
    end

    def mark_existing!(relationship)
      @record.update!(
        state: :completed,
        outcome: relationship.is_a?(FollowRequest) ? 'existing_follow_request' : 'existing_follow',
        relationship_recorded_at: Time.current,
        follow_id: relationship.is_a?(Follow) ? relationship.id : nil,
        follow_request_id: relationship.is_a?(FollowRequest) ? relationship.id : nil,
        finished_at: Time.current,
        claim_expires_at: nil,
        last_error: nil
      )
    end

    def mark_permanent!(code)
      @record.with_lock do
        @record.reload
        unless @record.discharged? || @record.succeeded? || @record.completed?
          @record.update!(
            state: :permanent_failure,
            last_error: code.to_s,
            finished_at: Time.current,
            claim_expires_at: nil
          )
        end
      end
    end

    def mark_failure!(code)
      @record.with_lock do
        @record.reload
        unless @record.discharged? || @record.terminal?
          exhausted = code.to_s != 'rate_limited' && @record.attempts >= GroupInitialFollow::MAX_ATTEMPTS
          if exhausted
            @record.update!(state: :permanent_failure, last_error: 'attempts_exhausted', finished_at: Time.current, claim_expires_at: nil)
          else
            @record.update!(state: :retryable_failure, last_error: code.to_s, claim_expires_at: nil)
          end
        end
      end
    end

    def latch_attributes(relationship)
      created = relationship.previously_new_record?
      if relationship.is_a?(FollowRequest)
        {
          outcome: created ? 'created_follow_request' : 'existing_follow_request',
          follow_request_id: relationship.id,
          follow_id: nil,
          relationship_recorded_at: Time.current,
          last_error: nil,
        }
      else
        {
          outcome: created ? 'created_follow' : 'existing_follow',
          follow_id: relationship.id,
          follow_request_id: nil,
          relationship_recorded_at: Time.current,
          last_error: nil,
        }
      end
    end

    def refusal_code
      reload_parties
      return :request_not_approved unless request.approved?
      return :group_unavailable if group.nil? || !group.local? || !group.group? || group.suspended?
      return :owner_unavailable unless GroupManagement.local_functional_person?(owner)
      return :owner_mismatch unless owner.id == request.requester_account_id

      nil
    end

    def existing_relationship
      reload_parties
      return if owner.nil? || group.nil?

      Follow.find_by(account_id: owner.id, target_account_id: group.id) ||
        FollowRequest.find_by(account_id: owner.id, target_account_id: group.id)
    end

    def reload_parties
      request.reload
      owner&.reload
      group&.reload
    end

    def request
      @request ||= @record.group_creation_request
    end

    def owner
      request.initial_owner_account
    end

    def group
      request.group_account
    end

    def fresh_discharged?
      @record.reload.discharged?
    end

    def error_code(error)
      code = error.class.name.demodulize.underscore
      code.match?(/\A[a-z0-9_]{1,64}\z/) ? code : 'unexpected'
    end

    def take_lock!
      key = Integer(@record.id)
      return false if key.negative? || key > 2_147_483_647

      held = @record.class.connection.select_value(
        "SELECT pg_try_advisory_lock(#{GroupInitialFollow::LOCK_NAMESPACE}, #{key})"
      )
      @locked = held == true || held.to_s == 't'
    end

    def release_lock!
      return unless @locked

      key = Integer(@record.id)
      @record.class.connection.select_value(
        "SELECT pg_advisory_unlock(#{GroupInitialFollow::LOCK_NAMESPACE}, #{key})"
      )
      @locked = false
    end
  end
end
