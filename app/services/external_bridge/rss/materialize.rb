# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Materialize
      def call(subscription:, resources:, complete: false)
        return unless subscription.state == 'active'
        return unless subscription.user&.functional?

        resources.each do |resource|
          project(subscription, resource)
        end
        mark_missing(subscription, resources) if complete
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
      rescue ActiveRecord::RecordNotUnique
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

      def mark_missing(subscription, resources)
        seen = resources.map(&:id)
        ExternalStatusProjection.where(external_subscription_id: subscription.id).where.not(external_resource_id: seen).find_each do |marker|
          marker.update!(source_deleted: true)
          resource = marker.external_resource
          next if resource.nil? || resource.source_deleted_at.present?

          resource.update!(source_deleted_at: Time.current)
        end
      end

      def status_text(resource)
        parts = [resource.title, resource.byline, resource.canonical_url, resource.body].map { |part| part.to_s.strip }.reject(&:blank?)
        text, = Sanitizer.capped(parts.join("\n\n"))
        text.presence || I18n.t('external_bridge.untitled')
      end
    end
  end
end
