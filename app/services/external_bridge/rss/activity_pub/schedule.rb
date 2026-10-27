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

        # NodeInfo advertises support by the feed HOST. Verified remote item
        # URLs alone do not establish that the RSS feed itself is AP-capable.
        def recompute_source!(source)
          # The shared fetch and AP probe may update the same source in separate
          # transactions. Re-read the latest NodeInfo evidence before deriving
          # the summary state instead of trusting the caller's stale instance.
          source.reload
          item_verified = source.external_resources.where(activitypub_state: 'verified', source_deleted_at: nil).exists?
          state = if source.activitypub_instance_state == 'verified'
                    'verified'
                  elsif item_verified
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
