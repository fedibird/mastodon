# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      module Schedule
        module_function

        def enabled?
          Feature.enabled? && ActiveModel::Type::Boolean.new.cast(Setting.external_bridge_rss_activitypub_discovery)
        end

        def permitted_source?(source)
          source.external_subscriptions.active.where(user_id: Feature.tester_ids).exists?
        end

        def due?(source)
          source.external_resources.where(source_deleted_at: nil).where.not(activitypub_candidate_url: nil)
                .where('activitypub_next_check_at IS NULL OR activitypub_next_check_at <= ?', Time.current).exists?
        end

        def enqueue_if_due(source)
          return false if source.nil? || !enabled? || !permitted_source?(source) || !due?(source)

          SourceProbeWorker.perform_async(source.id).present?
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] AP probe enqueue skipped source=#{source&.id} code=#{e.class}")
          false
        end

        # Feed-level evidence is deliberately conservative: one verified item
        # confirms at least one AP-retrievable object, not universal AP support.
        def recompute_source!(source)
          verified = source.external_resources.where(activitypub_state: 'verified', source_deleted_at: nil).exists?
          state = verified ? 'verified' : (source.activitypub_hint? ? 'hinted' : 'unknown')
          source.update_columns(activitypub_state: state) if source.activitypub_state != state
        end
      end
    end
  end
end
