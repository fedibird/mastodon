# frozen_string_literal: true

module ExternalBridge
  module VisibilityMigration
    # Marker primary key is the only driver. Status rows are loaded by id
    # after the page is chosen. There is no visibility scan of statuses.
    class Scanner
      def self.watermark(user_id:, subscription_id:)
        scoped(user_id, subscription_id).maximum(:id).to_i
      end

      def self.page(after:, watermark:, user_id:, subscription_id:, limit:)
        scoped(user_id, subscription_id)
          .where('external_status_projections.id > ? AND external_status_projections.id <= ?', after.to_i, watermark.to_i)
          .order(:id)
          .limit(limit.to_i)
          .to_a
      end

      def self.by_ids(marker_ids)
        ids = marker_ids.map { |id| Integer(id) }
        return [] if ids.empty?

        ExternalStatusProjection.where(id: ids).order(:id).to_a
      end

      def self.remaining(after:, watermark:, user_id:, subscription_id:)
        scoped(user_id, subscription_id)
          .where('external_status_projections.id > ? AND external_status_projections.id <= ?', after.to_i, watermark.to_i)
          .count
      end

      def self.relation(after:, watermark:, user_id:, subscription_id:, limit:)
        scoped(user_id, subscription_id)
          .where('external_status_projections.id > ? AND external_status_projections.id <= ?', after.to_i, watermark.to_i)
          .order(:id)
          .limit(limit.to_i)
      end

      def self.scoped(user_id, subscription_id)
        scope = ExternalStatusProjection.all
        scope = scope.where(user_id: user_id) if user_id
        scope = scope.where(external_subscription_id: subscription_id) if subscription_id
        scope
      end
      private_class_method :scoped
    end
  end
end
