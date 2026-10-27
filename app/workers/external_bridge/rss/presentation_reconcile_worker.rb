# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Rewrites one page of this subscription's projections to the generation
    # it was given. A newer save bumps presentation_revision; this pass then
    # stops and the newer pass starts from the first row. Deletion wins over
    # both: the fence refuses the write and this job does not retry it.
    class PresentationReconcileWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 5

      BATCH = 100
      LEASE = 5.minutes

      def perform(subscription_id, revision, after_id = 0)
        return unless hold(subscription_id, revision)

        ids = projection_ids(subscription_id, after_id)
        if ids.empty?
          finish!(subscription_id, revision)
          return
        end

        return unless apply_page(subscription_id, revision, ids)
        return unless still_current?(subscription_id, revision)

        self.class.perform_async(subscription_id, revision.to_i, ids.last)
      end

      sidekiq_retries_exhausted do |msg, _exception|
        subscription_id, revision, = msg['args']
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i)
                            .where('presentation_applied_revision < presentation_revision')
                            .where.not(state: ExternalSubscription::DELETING)
                            .update_all(presentation_error: 'reconcile_failed', presentation_lease_until: nil, updated_at: Time.current)
      end

      private

      def projection_ids(subscription_id, after_id)
        ExternalStatusProjection.where(external_subscription_id: subscription_id)
                                .where('id > ?', after_id.to_i)
                                .order(:id)
                                .limit(BATCH)
                                .pluck(:id)
      end

      # The share lock covers the read of the generation and the status
      # writes. A save or a purge waits until this page commits, so this page
      # cannot overwrite a generation it did not read.
      def apply_page(subscription_id, revision, ids)
        applied = false
        SubscriptionFence.guard!(subscription_id) do
          current = ExternalSubscription.where(id: subscription_id).pick(:presentation_revision, :media_sensitive, :cw_enabled)
          if current && current[0].to_i == revision.to_i
            policy = { media_sensitive: current[1], cw_enabled: current[2] }
            ExternalStatusProjection.where(id: ids).includes(:status, :external_resource).find_each do |marker|
              apply_marker(marker, policy)
            end
            applied = true
          end
        end
        applied
      rescue SubscriptionFence::Fenced
        false
      end

      def apply_marker(marker, policy)
        status = marker.status
        resource = marker.external_resource
        return if status.nil? || resource.nil?

        desired = Presentation.for(resource, **policy)
        return unless Presentation.apply!(status, desired)

        Streaming::Scheduler.bump_and_schedule_content!(marker)
      end

      def hold(subscription_id, revision)
        now = Time.current
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i)
                            .where('presentation_applied_revision < presentation_revision')
                            .where.not(state: ExternalSubscription::DELETING)
                            .update_all(presentation_lease_until: now + LEASE, presentation_error: nil, updated_at: now)
                            .positive?
      end

      def still_current?(subscription_id, revision)
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i)
                            .where.not(state: ExternalSubscription::DELETING)
                            .exists?
      end

      def finish!(subscription_id, revision)
        now = Time.current
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i)
                            .where.not(state: ExternalSubscription::DELETING)
                            .update_all(
                              presentation_applied_revision: revision.to_i,
                              presentation_error: nil,
                              presentation_lease_until: nil,
                              updated_at: now
                            )
      end
    end
  end
end
