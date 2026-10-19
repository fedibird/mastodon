# frozen_string_literal: true

module ExternalBridge
  module RSS
    class Materialize
      Result = Struct.new(:ran, :attempted, :succeeded, :failed, :skipped, keyword_init: true)

      def call(subscription:, resources:, retries: true)
        empty = Result.new(ran: false, attempted: 0, succeeded: 0, failed: 0, skipped: 0)
        return empty unless subscription.state == 'active'
        return empty unless subscription.user&.functional?
        return empty unless Feature.permitted?(subscription.user)

        result = Result.new(ran: true, attempted: 0, succeeded: 0, failed: 0, skipped: 0)
        resources_with_retries(subscription, resources, retries).each do |resource|
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

      def resources_with_retries(subscription, resources, retries)
        current = Array(resources)
        return current unless retries

        current_ids = current.map(&:id)
        failure_ids = ExternalProjectionFailure.where(user_id: subscription.user_id, external_subscription_id: subscription.id)
                                               .where.not(external_resource_id: current_ids)
                                               .where('attempt_count < ?', Limits::ITEM_ATTEMPT_CEILING)
                                               .where('next_attempt_at IS NULL OR next_attempt_at <= ?', Time.current)
                                               .order(:created_at, :id)
                                               .limit(Limits::MAX_ITEMS)
                                               .pluck(:external_resource_id)
        return current if failure_ids.empty?

        extras = ExternalResource.where(id: failure_ids).index_by(&:id)
        current + failure_ids.filter_map { |id| extras[id] }
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
        count = failure.attempt_count.to_i + 1
        failure.attempt_count = count
        failure.next_attempt_at = if count >= Limits::ITEM_ATTEMPT_CEILING
                                    nil
                                  else
                                    Time.current + RetryPolicy.delay(count, resource.id)
                                  end
        failure.save!
      end

      def clear_failure(subscription, resource)
        ExternalProjectionFailure.where(user_id: subscription.user_id, external_resource_id: resource.id).delete_all
      end
    end
  end
end
