# frozen_string_literal: true

module GroupAdministration
  # Persists one administration log row. A failure raises so the caller can
  # roll back the change it was auditing. Decision notes and storage keys
  # are not accepted here.
  class Audit
    class Error < StandardError; end

    def self.record!(account:, action:, target:, changes:)
      raise Error, 'missing audit target' if account.nil? || target.nil?

      entry = Admin::ActionLog.new(account: account, action: action.to_s, target: target)
      entry.recorded_changes = changes
      entry.save!
      entry
    rescue Error
      raise
    rescue StandardError => e
      Rails.logger.error("Group administration audit failed action=#{action} target_type=#{target.class.name} target_id=#{target.id} error=#{e.class}")
      raise Error
    end
  end
end
