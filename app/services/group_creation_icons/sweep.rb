# frozen_string_literal: true

module GroupCreationIcons
  # Removes private objects that no request row references. Drafts are not
  # rows, so the grace period must stay longer than DraftStore's TTL.
  class Sweep
    def self.call(older_than: SWEEP_GRACE, now: Time.current)
      storage = Storage.resolve
      return 0 unless storage.respond_to?(:sweep_unreferenced)

      storage.sweep_unreferenced(older_than: older_than, now: now) do |key|
        GroupCreationRequest.exists?(icon_storage_key: key)
      end
    rescue ConfigurationError
      0
    end
  end
end
