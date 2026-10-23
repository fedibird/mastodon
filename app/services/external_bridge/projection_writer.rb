# frozen_string_literal: true

module ExternalBridge
  # One transaction: status insert with the privacy bit, then the marker.
  # A failed marker rolls the status back before after_create_commit.
  class ProjectionWriter
    def create!(user:, subscription:, resource:, text:)
      raise Error, :user_not_functional unless user&.functional?
      raise Error, :account_mismatch unless user.account_id.present? && subscription.user_id == user.id
      raise Error, :account_mismatch unless subscription.external_source_id == resource.external_source_id

      visibility = storage_visibility
      ApplicationRecord.transaction(requires_new: true) do
        status = Status.create!(
          account_id: user.account_id,
          text: text.presence || I18n.t('external_bridge.untitled'),
          visibility: visibility,
          searchability: :personal,
          uri: nil,
          external_projection: true,
          local: true,
          reply: false,
          sensitive: false
        )
        marker = ExternalStatusProjection.create!(
          user_id: user.id,
          account_id: user.account_id,
          external_source_id: subscription.external_source_id,
          external_subscription_id: subscription.id,
          external_resource_id: resource.id,
          status_id: status.id,
          last_seen_revision: resource.revision,
          source_deleted: resource.source_deleted_at.present?
        )
        Streaming::Scheduler.bump_and_schedule_content!(marker) if visibility == :external
        [status, marker]
      end
    end

    private

    # The caller cannot choose visibility. The instance switch selects the
    # stored value. When it is on and this database cannot store external,
    # fail before inserting a personal or public row.
    def storage_visibility
      return :personal unless VisibilitySwitch.enabled?

      VisibilitySwitch.assert_database_ready!
      :external
    end
  end
end
