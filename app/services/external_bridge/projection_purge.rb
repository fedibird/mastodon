# frozen_string_literal: true

module ExternalBridge
  # Physical DELETE. Does not discard, does not call RemoveStatusService,
  # and does not enqueue ActivityPub Delete. SET LOCAL is transaction-scoped
  # so a rolled-back purge keeps the status and the marker.
  class ProjectionPurge
    SETTING_SQL = "SET LOCAL fedibird.projection_status_delete = 'on'"

    def self.purge_status!(status)
      purge_status_ids!([status.id], suppress: true)
    end

    def self.purge_status_ids!(status_ids, suppress: false)
      ids = Array(status_ids).map(&:to_i).uniq.reject(&:zero?)
      return if ids.empty?

      ActiveRecord::Base.transaction(requires_new: true) do
        remember_suppressions!(ids) if suppress
        ActiveRecord::Base.connection.execute(SETTING_SQL)
        Status.unscoped.where(id: ids).delete_all
      end

      ids.each { |id| Rails.cache.delete("statuses/#{id}") }
      remove_search_documents(ids)
    ensure
      clear_delete_setting!
    end

    def self.purge_user!(user)
      ids = ExternalStatusProjection.where(user_id: user.id).pluck(:status_id)
      purge_status_ids!(ids)
    end

    def self.purge_for_account!(account)
      user_ids = User.where(account_id: account.id).pluck(:id)
      ids = ExternalStatusProjection.where(user_id: user_ids).pluck(:status_id)
      account_ids = ExternalStatusProjection.where(account_id: account.id).pluck(:status_id)
      purge_status_ids!(ids + account_ids)
    end

    def self.purge_subscription!(subscription)
      ids = ExternalStatusProjection.where(external_subscription_id: subscription.id).pluck(:status_id)
      purge_status_ids!(ids)
    end

    def self.remember_suppressions!(status_ids)
      ExternalStatusProjection.where(status_id: status_ids).find_each do |marker|
        ExternalProjectionFailure.where(user_id: marker.user_id, external_resource_id: marker.external_resource_id).delete_all
        suppression = ExternalProjectionSuppression.find_or_initialize_by(user_id: marker.user_id, external_resource_id: marker.external_resource_id)
        suppression.save!
      end
    end
    private_class_method :remember_suppressions!

    def self.clear_delete_setting!
      connection = ActiveRecord::Base.connection
      return unless connection.transaction_open?

      connection.execute("SET LOCAL fedibird.projection_status_delete = 'off'")
    rescue StandardError
      nil
    end
    private_class_method :clear_delete_setting!

    def self.remove_search_documents(ids)
      return unless Chewy.enabled?

      Chewy.strategy.current.update(StatusesIndex, ids)
    rescue StandardError => e
      Rails.logger.warn("[ExternalBridge] search delete failed: #{e.class}")
    end
    private_class_method :remove_search_documents
  end
end
