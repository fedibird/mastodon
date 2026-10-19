# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Materialize
      def call(subscription:, resources:)
        return unless subscription.state == 'active'
        return unless subscription.user&.functional?
        return unless Feature.permitted?(subscription.user)

        resources.each do |resource|
          project(subscription, resource)
        end
      end

      private

      def project(subscription, resource)
        marker = ExternalStatusProjection.find_by(user_id: subscription.user_id, external_resource_id: resource.id)
        if marker
          refresh_existing(marker, resource)
        else
          ProjectionWriter.new.create!(
            user: subscription.user,
            subscription: subscription,
            resource: resource,
            text: status_text(resource)
          )
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, Error => e
        Rails.logger.info("[ExternalBridge::RSS] projection skipped subscription=#{subscription.id} code=#{e.class}")
        nil
      end

      def refresh_existing(marker, resource)
        marker.update!(
          last_seen_revision: resource.revision,
          source_deleted: resource.source_deleted_at.present?
        )
        status = marker.status
        return if status.nil?

        text = status_text(resource)
        status.update!(text: text) if status.text != text
      end

      def status_text(resource)
        Excerpt.for(resource)
      end
    end
  end
end
