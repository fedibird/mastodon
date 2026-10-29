# frozen_string_literal: true

module ExternalBridge
  # One transaction: status insert with the privacy bit, then the marker.
  # A failed marker rolls the status back before after_create_commit.
  # The subscription row is held FOR SHARE for the whole write, so a
  # subscription that is being removed (`deleting`) cannot gain a projection.
  class ProjectionWriter
    # text, sensitive, and spoiler_text default to the subscriber's current
    # display choices, read under the deletion fence. Callers that pass an
    # explicit text keep the previous fixed shape (no warning, not sensitive,
    # language unset).
    # rubocop:disable Metrics/ParameterLists
    def create!(user:, subscription:, resource:, text: :generated, sensitive: :generated, spoiler_text: :generated)
      raise Error, :user_not_functional unless user&.functional?
      raise Error, :account_mismatch unless user.account_id.present? && subscription.user_id == user.id
      raise Error, :account_mismatch unless subscription.external_source_id == resource.external_source_id

      visibility = storage_visibility
      RSS::SubscriptionFence.guard!(subscription) do
        fields = fields_for(subscription, resource, text, sensitive, spoiler_text)
        # created_at is the publication instant, chosen once. language is the
        # subscriber's choice, or nil when the caller passed an explicit text.
        # updated_at stays the save clock. Do not pass override_timestamps.
        status = Status.create!(
          account_id: user.account_id,
          text: fields.text,
          spoiler_text: fields.spoiler_text,
          visibility: visibility,
          searchability: :personal,
          uri: nil,
          external_projection: true,
          local: true,
          reply: false,
          sensitive: fields.sensitive,
          language: fields.language,
          created_at: RSS::PublicationTime.for_new_status(resource)
        )
        marker = ExternalStatusProjection.create!(
          user_id: user.id,
          account_id: user.account_id,
          external_source_id: subscription.external_source_id,
          external_subscription_id: subscription.id,
          external_resource_id: resource.id,
          status_id: status.id,
          last_seen_revision: resource.revision,
          last_seen_media_revision: resource.media_revision,
          last_seen_byline: resource.byline.to_s,
          source_deleted: resource.source_deleted_at.present?
        )
        RSS::Media::Sync.attach_ready!(marker, resource)
        Streaming::Scheduler.bump_and_schedule_content!(marker) if visibility == :external
        [status, marker]
      end
    end
    # rubocop:enable Metrics/ParameterLists

    private

    def fields_for(subscription, resource, text, sensitive, spoiler_text)
      if text == :generated && sensitive == :generated && spoiler_text == :generated
        policy = RSS::Presentation.snapshot(subscription.id)
        raise RSS::SubscriptionFence::Fenced if policy.nil?

        return RSS::Presentation.for(resource, **policy)
      end

      RSS::Presentation::Fields.new(
        text: text.presence || I18n.t('external_bridge.untitled'),
        spoiler_text: spoiler_text == :generated ? '' : spoiler_text.to_s,
        sensitive: sensitive == true,
        language: nil
      )
    end

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
