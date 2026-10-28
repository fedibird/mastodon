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
          DueResources.new(source).due?
        end

        def instance_due?(source)
          source.activitypub_instance_next_check_at.nil? || source.activitypub_instance_next_check_at <= Time.current
        end

        def enqueue_if_due(source)
          return false if source.nil? || !enabled? || !permitted_source?(source)
          return false unless instance_due?(source) || due?(source)

          SourceProbeWorker.perform_async(source.id).present?
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] AP probe enqueue skipped source=#{source&.id} code=#{e.class}")
          false
        end

        # Item evidence and the weak feed hint only. Host NodeInfo lives on
        # host_activitypub_supported. activitypub_feed_attribution "likely"
        # is a generator-and-same-host guess, not a confirmed origin. Neither
        # is copied into activitypub_state, and activitypub_state is never
        # "verified" (that word on a resource means the candidate URL returned
        # AS2, not that the feed host is an AP server).
        def recompute_source!(source)
          source.reload
          state = if DueResources.verified_items(source).exists?
                    'items_verified'
                  elsif source.activitypub_hint?
                    'hinted'
                  else
                    'unknown'
                  end
          source.update_columns(activitypub_state: state) if source.activitypub_state != state
        end
      end
    end
  end
end
