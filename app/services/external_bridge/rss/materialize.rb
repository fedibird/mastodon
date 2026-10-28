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
        run_resources(subscription, selectable_resources(subscription, resources, retries), result)
      rescue SubscriptionFence::Fenced
        # The subscription is being removed. Nothing more is written, and the
        # caller must not reconcile counters for a run that was cut short.
        empty
      end

      private

      def run_resources(subscription, selected, result)
        selected.each do |resource|
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
        judge_videos = if marker
                         refresh_existing(marker, resource) == :media
                       else
                         ProjectionWriter.new.create!(
                           user: subscription.user,
                           subscription: subscription,
                           resource: resource
                         )
                         true
                       end
        safe_enqueue(resource, videos: judge_videos)
        true
      rescue SubscriptionFence::Fenced
        raise
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, Error => e
        Rails.logger.info("[ExternalBridge::RSS] projection skipped subscription=#{subscription.id} code=#{e.class}")
        false
      end

      def refresh_existing(marker, resource)
        status = marker.status
        return if status.nil?

        deleted = resource.source_deleted_at.present?
        deleted_changed = marker.source_deleted != deleted
        revision_changed = marker.last_seen_revision.to_s != resource.revision.to_s
        media_changed = media_revision_changed?(marker, resource)
        links_stale = Media::Sync.links_stale?(marker, resource)
        # A quick read avoids the share lock when nothing moved. The write
        # below reads the choices again under that lock, so a save that
        # committed in between is the one stored. A save that commits after
        # the lock is the reconcile job's to apply.
        policy = Presentation.snapshot(marker.external_subscription_id)
        raise SubscriptionFence::Fenced if policy.nil?

        desired = Presentation.for(resource, **policy)
        presentation_changed = Presentation.changed?(status, desired)
        marker_changed = deleted_changed || revision_changed || media_changed || links_stale
        return :skip unless presentation_changed || marker_changed

        outcome = :skip
        SubscriptionFence.guard!(marker.external_subscription_id) do
          locked = Presentation.snapshot(marker.external_subscription_id)
          raise SubscriptionFence::Fenced if locked.nil?

          # The resource argument may be a snapshot from before this lock.
          # Another import can commit a newer article while this refresh
          # waits, so the row is read again after the projection lock.
          ProjectionWrite.latest(marker.id) do |fresh_marker, fresh_status, fresh_resource|
            fresh_desired = Presentation.for(fresh_resource, **locked)
            fresh_deleted = fresh_resource.source_deleted_at.present?
            fresh_deleted_changed = fresh_marker.source_deleted != fresh_deleted
            fresh_revision_changed = fresh_marker.last_seen_revision.to_s != fresh_resource.revision.to_s
            fresh_media_changed = media_revision_changed?(fresh_marker, fresh_resource)
            fresh_links_stale = Media::Sync.links_stale?(fresh_marker, fresh_resource)
            fresh_presentation_changed = Presentation.changed?(fresh_status, fresh_desired)
            next unless fresh_presentation_changed || fresh_deleted_changed || fresh_revision_changed || fresh_media_changed || fresh_links_stale

            write_refresh!(
              fresh_marker,
              fresh_status,
              fresh_resource,
              {
                text: fresh_desired.text,
                spoiler_text: fresh_desired.spoiler_text,
                sensitive: fresh_desired.sensitive,
                language: fresh_desired.language,
                deleted: fresh_deleted,
                presentation_changed: fresh_presentation_changed,
                deleted_changed: fresh_deleted_changed,
                revision_changed: fresh_revision_changed,
                media_changed: fresh_media_changed,
                links_stale: fresh_links_stale,
              }
            )
            outcome = if fresh_media_changed
                        :media
                      elsif fresh_links_stale
                        :links
                      else
                        :text
                      end
          end
        end
        outcome
      end

      def write_refresh!(marker, status, resource, change)
        if change[:revision_changed] || change[:deleted_changed] || change[:media_changed]
          marker.update!(
            last_seen_revision: resource.revision,
            source_deleted: change[:deleted],
            last_seen_media_revision: resource.media_revision
          )
        end
        if change[:presentation_changed]
          status.update!(
            text: change[:text],
            spoiler_text: change[:spoiler_text],
            sensitive: change[:sensitive],
            language: change[:language]
          )
          Rails.cache.delete("statuses/#{status.id}")
        end
        files_changed = change[:media_changed] || change[:links_stale]
        Media::Sync.attach_ready!(marker, resource) if files_changed
        if files_changed && !change[:presentation_changed]
          status.update_columns(updated_at: Time.current)
          Rails.cache.delete("statuses/#{status.id}")
        end
        if change[:deleted_changed]
          schedule_membership_change!(marker, change[:deleted])
        elsif change[:presentation_changed] || files_changed
          Streaming::Scheduler.bump_and_schedule_content!(marker)
        end
      end

      # A nil last-seen and an empty candidate digest are the same "no media"
      # state. Treating them as a change would stream every existing projection
      # once on the deploy that starts recording media. Fallback-only edits
      # stay off this digest. Sync.links_stale? reconciles those separately.
      def media_revision_changed?(marker, resource)
        seen = marker.last_seen_media_revision
        current = resource.media_revision
        return false if seen.blank? && current.blank?
        return false if seen.blank? && Array(resource.media_candidates).empty?

        seen.to_s != current.to_s
      end

      def safe_enqueue(resource, videos: false)
        Media::Sync.enqueue!(resource, videos: videos)
      rescue StandardError => e
        Rails.logger.info("[ExternalBridge::RSS] media enqueue error=#{e.class}")
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
        SubscriptionFence.guard!(subscription) { failure.save! }
      end

      def clear_failure(subscription, resource)
        ExternalProjectionFailure.where(user_id: subscription.user_id, external_resource_id: resource.id).delete_all
      end
    end
  end
end
