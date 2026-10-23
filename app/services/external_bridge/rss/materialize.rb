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
        selectable_resources(subscription, resources, retries).each do |resource|
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

      # A new current item is imported immediately. A known failure, whether it is
      # still in this page or only in the history, runs when its own attempt is
      # due and still under the ceiling. An offer (retries: false) does not pull
      # history and does not spend a parked or not-yet-due failure.
      def selectable_resources(subscription, resources, retries)
        current = Array(resources)
        known = known_failures_for(subscription, current)
        selected = current.select { |resource| import_now?(known[resource.id], retries) }
        return selected unless retries

        extra_ids = historical_failure_ids(subscription, current)
        return selected if extra_ids.empty?

        extras = ExternalResource.where(id: extra_ids).index_by(&:id)
        selected + extra_ids.filter_map { |id| extras[id] }
      end

      # Only the ids on this page. A long failure history stays in the
      # separately limited historical query below.
      def known_failures_for(subscription, current)
        ids = current.map(&:id)
        return {} if ids.empty?

        ExternalProjectionFailure.where(
          user_id: subscription.user_id,
          external_subscription_id: subscription.id,
          external_resource_id: ids
        ).index_by(&:external_resource_id)
      end

      def historical_failure_ids(subscription, current)
        scope = ExternalProjectionFailure.where(user_id: subscription.user_id, external_subscription_id: subscription.id)
        scope = scope.where.not(external_resource_id: current.map(&:id)) if current.any?
        scope.where('attempt_count < ?', Limits::ITEM_ATTEMPT_CEILING)
             .where('next_attempt_at IS NULL OR next_attempt_at <= ?', Time.current)
             .order(:created_at, :id)
             .limit(Limits::MAX_ITEMS)
             .pluck(:external_resource_id)
      end

      def import_now?(failure, retries)
        return true if failure.nil?
        return false unless retries

        failure.attempt_count.to_i < Limits::ITEM_ATTEMPT_CEILING &&
          (failure.next_attempt_at.nil? || failure.next_attempt_at <= Time.current)
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
        status = marker.status
        return if status.nil?

        text = status_text(resource)
        deleted = resource.source_deleted_at.present?
        text_changed = status.text != text
        deleted_changed = marker.source_deleted != deleted
        revision_changed = marker.last_seen_revision.to_s != resource.revision.to_s
        return unless text_changed || deleted_changed || revision_changed

        change = {
          text: text,
          deleted: deleted,
          text_changed: text_changed,
          deleted_changed: deleted_changed,
          revision_changed: revision_changed,
        }
        ApplicationRecord.transaction do
          write_refresh!(marker, status, resource, change)
        end
      end

      def write_refresh!(marker, status, resource, change)
        if change[:revision_changed] || change[:deleted_changed]
          marker.update!(last_seen_revision: resource.revision, source_deleted: change[:deleted])
        end
        status.update!(text: change[:text]) if change[:text_changed]
        if change[:deleted_changed]
          schedule_membership_change!(marker, change[:deleted])
        elsif change[:text_changed]
          Streaming::Scheduler.bump_and_schedule_content!(marker)
        end
      end

      def schedule_membership_change!(marker, deleted)
        subscription = marker.external_subscription
        targets = subscription.external_feed_routes.filter_map { |route| route_target(route) }
        Streaming::Scheduler.schedule_control!(
          user_id: marker.user_id,
          subscription_id: marker.external_subscription_id,
          reason: deleted ? 'source_deleted' : 'source_restored',
          revision: subscription.feed_routes_revision,
          status_id: marker.status_id,
          targets: targets
        )
      end

      def route_target(route)
        return { 'type' => 'home' } if route.destination == 'home'
        return nil if route.list_id.blank?

        { 'type' => 'list', 'id' => route.list_id.to_s }
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
