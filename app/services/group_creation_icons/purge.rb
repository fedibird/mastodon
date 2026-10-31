# frozen_string_literal: true

module GroupCreationIcons
  # Deletes the staged original after a cancelled or rejected request commits.
  # A pending or approved request is left alone so P2 can still copy it.
  # Object deletion is idempotent. icon_purged_at is set only after delete
  # returns, including when the object was already gone.
  class Purge
    def self.call(request)
      request.with_lock do
        next true unless request.rejected? || request.cancelled?
        next true if request.icon_storage_key.blank? || request.icon_purged_at.present?

        Storage.resolve.delete(request.icon_storage_key)
        request.update!(icon_purged_at: Time.current)
        true
      end
    rescue StandardError => e
      Rails.logger.error("Group creation icon purge failed request_id=#{request.id} error=#{e.class}")
      false
    end

    def self.purge_terminal
      counts = { purged: 0, failed: 0 }
      terminal_scope.find_each do |request|
        if call(request)
          counts[:purged] += 1
        else
          counts[:failed] += 1
        end
      end
      counts
    end

    def self.terminal_scope
      GroupCreationRequest.where(state: GroupCreationRequest.states.values_at('rejected', 'cancelled'))
                          .where.not(icon_storage_key: nil)
                          .where(icon_purged_at: nil)
    end
  end
end
