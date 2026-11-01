# frozen_string_literal: true

module GroupInitialFollows
  # Re-enqueues rows whose first enqueue was missed, or whose worker stopped
  # before the terminal marker. It does not create rows, so groups approved
  # before this table existed are never followed from here.
  class Recovery
    def self.call
      new.call
    end

    def call
      enqueued = 0
      GroupInitialFollow.recovery_request_ids.each do |request_id|
        Worker.perform_async(request_id)
        enqueued += 1
      rescue StandardError => e
        Rails.logger.error("Group initial follow recovery enqueue failed request_id=#{request_id} error=#{e.class}")
      end
      enqueued
    end
  end
end
