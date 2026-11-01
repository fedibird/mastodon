# frozen_string_literal: true

module GroupInitialFollows
  # Administrator retry. Authorization is checked here, not only in the
  # HTTP filter. A discharged row is refused, including one whose follow
  # was removed, so this cannot put the follow back.
  class Retry
    def self.call(request:, actor_account:)
      new(request, actor_account).call
    end

    def initialize(request, actor_account)
      @request = request
      @actor_account = actor_account
    end

    def call
      return :not_authorized unless GroupManagement.server_administrator?(@actor_account)

      record = @request.initial_follow
      return :not_applicable if record.nil?

      reopened = reopen!(record)
      return reopened unless reopened == :ready

      Worker.perform_async(@request.id)
      :enqueued
    rescue StandardError => e
      Rails.logger.error("Group initial follow retry failed request_id=#{@request.id} error=#{e.class}")
      :enqueue_failed
    end

    private

    def reopen!(record)
      result = :not_retryable
      record.with_lock do
        record.reload
        result = if record.discharged? || record.succeeded? || record.completed?
                   :already_done
                 elsif record.claim_held?
                   :busy
                 elsif !retryable?(record)
                   :not_retryable
                 else
                   record.update!(
                     state: :pending,
                     last_error: nil,
                     finished_at: nil,
                     claim_expires_at: nil,
                     claim_token: nil,
                     attempts: 0
                   )
                   :ready
                 end
      end
      result
    end

    def retryable?(record)
      return true if record.retryable_failure? || record.permanent_failure?
      return true if record.pending? && record.last_error.present?
      return true if record.processing? && !record.claim_held?

      false
    end
  end
end
