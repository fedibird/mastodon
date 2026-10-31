# frozen_string_literal: true

module GroupCreationIcons
  # Hourly pass over approved icons that are not finished. One failure is
  # recorded on that request and does not stop the rest. Copy attempts stop
  # at Copy::MAX_ATTEMPTS. Deleting the private original keeps retrying
  # after a successful copy so a failed cleanup is not left behind.
  class HandoffRecovery
    def self.call
      counts = { finished: 0, pending: 0, failed: 0 }
      scope.find_each do |request|
        Copy.call(request)
        request.reload
        if request.icon_purged_at.present?
          counts[:finished] += 1
        else
          counts[:pending] += 1
        end
      rescue StandardError => e
        counts[:failed] += 1
        Rails.logger.error("Group creation icon handoff failed request_id=#{request.id} error=#{e.class}")
      end
      counts
    end

    def self.scope
      GroupCreationRequest.approved
                          .where.not(icon_storage_key: nil)
                          .where(icon_purged_at: nil)
                          .where('icon_handoff_copied_at IS NOT NULL OR icon_handoff_attempts < ?', Copy::MAX_ATTEMPTS)
    end
  end
end
