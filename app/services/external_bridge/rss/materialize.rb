# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Materialize
      Result = Struct.new(:ran, :attempted, :succeeded, :failed, :skipped, keyword_init: true)

      def call(subscription:, resources:)
        empty = Result.new(ran: false, attempted: 0, succeeded: 0, failed: 0, skipped: 0)
        return empty unless subscription.state == 'active'
        return empty unless subscription.user&.functional?
        return empty unless Feature.permitted?(subscription.user)

        result = Result.new(ran: true, attempted: 0, succeeded: 0, failed: 0, skipped: 0)
        resources_with_retries(subscription, resources).each do |resource|
          if suppressed?(subscription, resource)
            result.skipped += 1
            next
          end

          result.attempted += 1
          if project(subscription, resource)
            result.succeeded += 1
            clear_failure(subscription, resource)
          else
            result.failed += 1
            record_failure(subscription, resource)
          end
        end
        result
      end

      private

      def resources_with_retries(subscription, resources)
        current = Array(resources)
        extra_ids = ExternalProjectionFailure.where(user_id: subscription.user_id, external_subscription_id: subscription.id).pluck(:external_resource_id)
        missing_ids = extra_ids - current.map(&:id)
        return current if missing_ids.empty?

        current + ExternalResource.where(id: missing_ids).to_a
      end

      def suppressed?(subscription, resource)
        ExternalProjectionSuppression.exists?(user_id: subscription.user_id, external_resource_id: resource.id)
      end

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
        true
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, Error => e
        Rails.logger.info("[ExternalBridge::RSS] projection skipped subscription=#{subscription.id} code=#{e.class}")
        false
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

      def record_failure(subscription, resource)
        failure = ExternalProjectionFailure.find_or_initialize_by(user_id: subscription.user_id, external_resource_id: resource.id)
        failure.external_subscription = subscription
        failure.error_code = 'import_failed'
        failure.save!
      end

      def clear_failure(subscription, resource)
        ExternalProjectionFailure.where(user_id: subscription.user_id, external_resource_id: resource.id).delete_all
      end
    end
  end
end
