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
      # Released with the page transaction. A second pass of the same
      # subscription skips instead of writing those statuses again.
      LOCK_CLASS = 810_533

      # One token owns the generation. The update matches only an expired
      # lease, so two callers cannot both leave holding a token.
      def self.claim(subscription_id, revision)
        token = SecureRandom.hex(16)
        now = Time.current
        updated = ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i)
                                      .where('presentation_applied_revision < presentation_revision')
                                      .where.not(state: ExternalSubscription::DELETING)
                                      .where('presentation_lease_until IS NULL OR presentation_lease_until <= ?', now)
                                      .update_all(
                                        presentation_lease_token: token,
                                        presentation_lease_until: now + LEASE,
                                        presentation_error: nil,
                                        updated_at: now
                                      )
        updated.positive? ? token : nil
      end

      def perform(subscription_id, revision, after_id = 0, token = nil)
        return unless hold(subscription_id, revision, token)

        ids = projection_ids(subscription_id, after_id)
        if ids.empty?
          finish!(subscription_id, revision, token)
          return
        end

        return unless apply_page(subscription_id, revision, ids, token)
        return unless still_current?(subscription_id, revision, token)

        self.class.perform_async(subscription_id, revision.to_i, ids.last, token)
      end

      sidekiq_retries_exhausted do |msg, _exception|
        subscription_id, revision, = msg['args']
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i)
                            .where('presentation_applied_revision < presentation_revision')
                            .where.not(state: ExternalSubscription::DELETING)
                            .update_all(
                              presentation_error: 'reconcile_failed',
                              presentation_lease_until: nil,
                              presentation_lease_token: nil,
                              updated_at: Time.current
                            )
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
      def apply_page(subscription_id, revision, ids, token)
        applied = false
        SubscriptionFence.guard!(subscription_id) do
          if page_lock?(subscription_id)
            current = ExternalSubscription.where(id: subscription_id).pick(
              :presentation_revision, :presentation_lease_token, :media_sensitive, :cw_enabled
            )
            if current && current[0].to_i == revision.to_i && current[1] == token
              policy = { media_sensitive: current[2], cw_enabled: current[3] }
              ExternalStatusProjection.where(id: ids).includes(:status, :external_resource).find_each do |marker|
                apply_marker(marker, policy)
              end
              applied = true
            end
          end
        end
        applied
      rescue SubscriptionFence::Fenced
        false
      end

      def page_lock?(subscription_id)
        locked = ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array(
            ['SELECT pg_try_advisory_xact_lock(?, ?)', LOCK_CLASS, subscription_id.to_i]
          )
        )
        locked == true || locked.to_s == 't'
      end

      def apply_marker(marker, policy)
        status = marker.status
        resource = marker.external_resource
        return if status.nil? || resource.nil?

        desired = Presentation.for(resource, **policy)
        return unless Presentation.apply!(status, desired)

        Streaming::Scheduler.bump_and_schedule_content!(marker)
      end

      # Extends the lease only for the token that already owns it. An expired
      # lease is taken by claim, which replaces the token, so a delayed worker
      # from the previous claim cannot resume beside the new one.
      def hold(subscription_id, revision, token)
        return false if token.blank?

        now = Time.current
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i, presentation_lease_token: token)
                            .where('presentation_applied_revision < presentation_revision')
                            .where.not(state: ExternalSubscription::DELETING)
                            .update_all(presentation_lease_until: now + LEASE, presentation_error: nil, updated_at: now)
                            .positive?
      end

      def still_current?(subscription_id, revision, token)
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i, presentation_lease_token: token)
                            .where.not(state: ExternalSubscription::DELETING)
                            .exists?
      end

      def finish!(subscription_id, revision, token)
        now = Time.current
        ExternalSubscription.where(id: subscription_id, presentation_revision: revision.to_i, presentation_lease_token: token)
                            .where.not(state: ExternalSubscription::DELETING)
                            .update_all(
                              presentation_applied_revision: revision.to_i,
                              presentation_error: nil,
                              presentation_lease_until: nil,
                              presentation_lease_token: nil,
                              updated_at: now
                            )
      end
    end
  end
end
