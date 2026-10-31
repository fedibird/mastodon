# frozen_string_literal: true

module GroupCreationIcons
  # Deletes the staged original after a cancelled or rejected request commits.
  # A pending or approved request is left alone so P2 can still copy it.
  # Object deletion is idempotent. icon_purged_at is set only after delete
  # returns, including when the object was already gone.
  class Purge
    def self.call(request)
      request.with_lock do
        next unless request.rejected? || request.cancelled?
        next if request.icon_storage_key.blank? || request.icon_purged_at.present?

        Storage.resolve.delete(request.icon_storage_key)
        request.update!(icon_purged_at: Time.current)
      end
    rescue Error => e
      Rails.logger.error("Group creation icon purge failed request_id=#{request.id} error=#{e.class}")
      false
    end
  end
end
