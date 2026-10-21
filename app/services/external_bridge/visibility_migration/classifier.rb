# frozen_string_literal: true

module ExternalBridge
  module VisibilityMigration
    # Reads unscoped status rows. default_scope hides deleted_at and would
    # mis-classify those projections as missing.
    class Classifier
      PERSONAL = Schema::PERSONAL_VISIBILITY
      EXTERNAL = Schema::EXTERNAL_VISIBILITY

      def initialize(markers)
        @markers = markers
        @statuses = load_statuses
        @users = load_users
        @subscriptions = load_subscriptions
        @resources = load_resources
      end

      def classify_all
        @markers.map { |marker| classify(marker) }
      end

      def classify(marker)
        status = @statuses[marker.status_id]
        return row(marker, :invalid, :missing_status) if status.nil?
        return classify_external(marker, status) if external_shape?(status)
        return row(marker, :invalid, shape_reason(status)) unless legacy_shape?(status)

        reason = relation_reason(marker, status)
        return row(marker, :invalid, reason) if reason

        row(marker, :eligible, nil)
      end

      private

      def row(marker, kind, reason)
        { marker_id: marker.id, status_id: marker.status_id, kind: kind, reason: reason }
      end

      def load_statuses
        Status.unscoped.where(id: @markers.map(&:status_id)).index_by(&:id)
      end

      def load_users
        User.where(id: @markers.map(&:user_id)).pluck(:id, :account_id).to_h
      end

      def load_subscriptions
        ids = @markers.map(&:external_subscription_id)
        ExternalSubscription.where(id: ids).pluck(:id, :user_id, :external_source_id).each_with_object({}) do |row, map|
          map[row[0]] = [row[1], row[2]]
        end
      end

      def load_resources
        ExternalResource.where(id: @markers.map(&:external_resource_id)).pluck(:id, :external_source_id).to_h
      end

      def classify_external(marker, status)
        reason = relation_reason(marker, status)
        return row(marker, :invalid, reason) if reason

        row(marker, :already_external, nil)
      end

      def legacy_shape?(status)
        shape?(status, PERSONAL)
      end

      def external_shape?(status)
        shape?(status, EXTERNAL)
      end

      def shape?(status, visibility)
        status.visibility_before_type_cast == visibility &&
          status.external_projection == true &&
          status.read_attribute(:local) == true &&
          status.uri.nil? &&
          status.searchability_before_type_cast == PERSONAL &&
          status.reply != true &&
          status.in_reply_to_id.nil? &&
          status.reblog_of_id.nil? &&
          status.quote_id.nil? &&
          status.deleted_at.nil?
      end

      def shape_reason(status)
        return :flag_not_set unless status.external_projection == true
        return :shape_invalid if [PERSONAL, EXTERNAL].include?(status.visibility_before_type_cast)

        :visibility_not_personal
      end

      def relation_reason(marker, status)
        return :account_mismatch unless @users[marker.user_id] == marker.account_id && marker.account_id == status.account_id

        subscription = @subscriptions[marker.external_subscription_id]
        return :subscription_mismatch unless subscription == [marker.user_id, marker.external_source_id]
        return :resource_mismatch unless @resources[marker.external_resource_id] == marker.external_source_id

        nil
      end
    end
  end
end
