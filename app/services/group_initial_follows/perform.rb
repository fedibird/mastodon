# frozen_string_literal: true

module GroupInitialFollows
  # Runs the one-time follow for a founding owner.
  #
  # There is no session advisory lock. PgBouncer transaction pooling can
  # move the next statement to another PostgreSQL backend, so a session
  # lock taken on one statement is not held or released on the next.
  # Exclusion is a row lock plus a claim token:
  #
  # 1. A short transaction sets processing, claim_token, and claim_expires_at.
  # 2. The follow transaction locks the row again and continues only when
  #    that token is still the live lease. A worker whose lease expired
  #    while it was outside this transaction does not create a follow.
  # 3. FollowService creates the row with defer_distribution. The discharge
  #    timestamp commits in that same transaction. Sidekiq, NotifyService,
  #    and the Redis counters stay on the FollowService instance until
  #    flush_distribution!, which runs only after commit. A rollback
  #    therefore leaves no delivery job and the follow is not visible yet.
  # 4. The terminal state is a later commit. If the process dies after the
  #    follow commits, resume finalizes the marker and distributes only
  #    when that same follow row still exists. An unfollow in the gap is
  #    not replaced.
  class Perform
    class Crash < StandardError; end

    def self.call(record, crash_after: nil, after_claim: nil)
      new(record, crash_after, after_claim).call
    end

    def initialize(record, crash_after, after_claim)
      @record = record
      @crash_after = crash_after
      @after_claim = after_claim
      @token = nil
    end

    def call
      execute
    end

    private

    def execute
      @record.reload
      return if @record.terminal?

      if @record.discharged?
        publish_persisted!
        finalize!
        return
      end

      @token = claim!
      return if @token.nil?

      @after_claim&.call
      @record.reload
      return if @record.terminal?

      if @record.discharged?
        publish_persisted!
        finalize!
        return
      end
      return unless owns?(@token)

      service = create_and_latch!(@token)
      return if service.nil?
      return unless @record.reload.discharged?

      publish!(service)
      finalize!
    rescue Crash
      # Drop only this worker's lease. A newer claim_token must stay.
      release_claim!(@token)
      raise
    rescue Mastodon::NotPermittedError
      mark_permanent!(:not_permitted, @token)
    rescue ActiveRecord::RecordNotFound
      mark_permanent!(:not_possible, @token)
    rescue Mastodon::RateLimitExceededError
      mark_failure!(:rate_limited, @token)
    rescue ActiveRecord::RecordInvalid
      mark_failure!(:invalid_follow, @token)
      raise
    rescue StandardError => e
      mark_failure!(error_code(e), @token)
      raise
    end

    def claim!
      token = SecureRandom.uuid
      owned = false
      @record.with_lock do
        @record.reload
        if claimable?
          @record.update!(
            state: :processing,
            claim_token: token,
            claim_expires_at: GroupInitialFollow::LEASE.from_now,
            attempts: @record.attempts + 1,
            last_error: nil
          )
          owned = true
        end
      end
      token if owned
    end

    # Expire this worker's lease only. After another worker has stored its
    # own claim_token, or after distribution was recorded, this is a no-op.
    def release_claim!(token)
      return if token.nil?

      @record.with_lock do
        @record.reload
        if @record.claim_token == token && @record.distribution_enqueued_at.nil? && !@record.terminal?
          @record.update!(claim_expires_at: 1.second.ago)
        end
      end
    end

    def claimable?
      !@record.terminal? && !@record.discharged? && !@record.claim_held?
    end

    def owns?(token)
      @record.claim_token == token && @record.claim_held?
    end

    # The token is checked again under the row lock before FollowService
    # runs. Losing the lease commits nothing from this transaction.
    def create_and_latch!(token)
      service = nil
      latched = false
      ApplicationRecord.transaction(requires_new: true) do
        @record.lock!
        @record.reload
        next if @record.terminal? || @record.discharged? || !owns?(token)

        @record.update!(claim_expires_at: GroupInitialFollow::LEASE.from_now)
        if (existing = existing_relationship)
          mark_existing!(existing)
          next
        end
        if (refusal = refusal_code)
          mark_permanent!(refusal, token)
          next
        end

        service = FollowService.new
        relationship = service.call(owner, group, with_rate_limit: true, defer_distribution: true)
        raise Crash, 'after_relationship_insert' if @crash_after == :after_relationship_insert

        if relationship.nil?
          mark_failure!(:empty_relationship, token)
          service = nil
          next
        end

        @record.update!(
          latch_attributes(relationship).merge(
            claim_token: token,
            claim_expires_at: GroupInitialFollow::LEASE.from_now,
            home_feed_partial_required: service.deferred_home_partial?
          )
        )
        latched = true
      end
      raise Crash, 'after_latch_commit' if latched && @crash_after == :after_latch_commit

      service if latched
    end

    # One worker owns distribution. The row lock decides. A second worker
    # that sees a live lease or distribution_enqueued_at does not send.
    # The follow row is loaded inside that lock; a missing row means the
    # person already unfollowed, so the timestamp is stored and nothing
    # is sent. The timestamp is stored only after a successful send, while
    # this token is still the claim. A crash during the send leaves the
    # lease. After it expires, one later worker may send the full set
    # again. That is the only at-least-once window.
    def publish!(service)
      relationship = reserve_distribution!(@token)
      return unless relationship

      service.flush_distribution!
      finish_distribution!(@token)
    end

    def publish_persisted!
      token = @token || SecureRandom.uuid
      relationship = reserve_distribution!(token)
      return unless relationship

      FollowService.distribute_persisted!(
        relationship,
        home_feed_partial_required: @record.home_feed_partial_required?,
        attempted_at: @record.relationship_recorded_at
      )
      finish_distribution!(token)
    end

    def reserve_distribution!(token)
      reserved = nil
      @record.with_lock do
        @record.reload
        if @record.distribution_enqueued_at.nil? && @record.discharged? && @record.outcome.to_s.start_with?('created_')
          relationship = created_relationship
          if relationship.nil?
            @record.update!(distribution_enqueued_at: Time.current)
          elsif !(@record.claim_held? && @record.claim_token != token)
            @record.update!(claim_token: token, claim_expires_at: GroupInitialFollow::LEASE.from_now)
            reserved = relationship
          end
        end
      end
      reserved
    end

    def finish_distribution!(token)
      @record.with_lock do
        @record.reload
        if @record.claim_token == token && @record.distribution_enqueued_at.nil?
          @record.update!(distribution_enqueued_at: Time.current)
        end
      end
    end

    def created_relationship
      Follow.find_by(id: @record.follow_id) || FollowRequest.find_by(id: @record.follow_request_id)
    end

    def finalize!
      @record.with_lock do
        @record.reload
        # Leave the distribution lease in place until the send is recorded.
        # Another worker must not clear it and start a second send.
        if !@record.terminal? && @record.discharged? && !distribution_outstanding?
          state = @record.outcome.to_s.start_with?('existing_') ? :completed : :succeeded
          @record.update!(state: state, finished_at: Time.current, claim_expires_at: nil, last_error: nil)
        end
      end
    end

    def distribution_outstanding?
      @record.outcome.to_s.start_with?('created_') && @record.distribution_enqueued_at.nil?
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

    def mark_permanent!(code, token)
      return if token.nil?

      @record.with_lock do
        @record.reload
        if @record.claim_token == token && !@record.discharged? && !@record.terminal?
          @record.update!(
            state: :permanent_failure,
            last_error: code.to_s,
            finished_at: Time.current,
            claim_expires_at: nil
          )
        end
      end
    end

    def mark_failure!(code, token)
      return if token.nil?

      @record.with_lock do
        @record.reload
        if @record.claim_token == token && !@record.discharged? && !@record.terminal?
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
  end
end
