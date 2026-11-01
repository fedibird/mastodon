# frozen_string_literal: true

module GroupCreationIcons
  # Asks the existing handoff worker to run again. An exhausted copy is
  # resumed through GroupCreationRequest#resume_icon_handoff! first. This
  # does not approve a request or create a group.
  class RetryHandoff
    def self.call(request:, actor_account:)
      new(request, actor_account).call
    end

    def initialize(request, actor_account)
      @request = request
      @actor_account = actor_account
    end

    def call
      return :not_authorized unless GroupManagement.server_administrator?(@actor_account)

      resumed = false
      @request.with_lock do
        return :not_retryable unless retryable?

        if exhausted?
          @request.resume_icon_handoff!
          resumed = true
        end
      end

      HandoffWorker.perform_async(@request.id)
      resumed ? :resumed : :enqueued
    rescue ActiveRecord::RecordInvalid
      :not_retryable
    rescue StandardError => e
      Rails.logger.error("Group creation icon retry enqueue failed request_id=#{@request.id} error=#{e.class}")
      :enqueue_failed
    end

    private

    def retryable?
      @request.approved? && @request.icon_storage_key.present? && @request.icon_purged_at.nil?
    end

    def exhausted?
      @request.icon_handoff_copied_at.nil? && @request.icon_handoff_attempts.to_i >= Copy::MAX_ATTEMPTS
    end
  end
end
