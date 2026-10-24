# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Shared-source fetch versus per-subscription retry accounting.
    #
    # Scheduler (no subscription_id): fetch when at least one active allowed
    # subscription is due. HTTP failure increments retry state only for those
    # due rows. A subscriber whose next_retry_at is still in the future keeps
    # that deadline and retry_count. On success the new public items are also
    # offered to the other active allowed subscribers, without reconcile, without
    # their historical failure backlog, and without changing their counters.
    #
    # Targeted resume (subscription_id): that subscription is the only row whose
    # failure and retry state can change, even when its deadline has not arrived.
    # Other subscribers are offered a successful cache fill on the same terms.
    class RefreshSource
      # Returns the log fields of this run (outcome, http_status, counters). The
      # same fields are written as one INFO line; they never carry a URL, header,
      # feed text, or exception message.
      def call(source_id, subscription_id: nil)
        started = RefreshLog.now
        @fields = {}
        @stage = nil
        outcome = run(source_id, subscription_id)
        record(source_id, subscription_id, outcome, started)
      rescue StandardError => e
        record(source_id, subscription_id, 'unexpected_error', started || RefreshLog.now, error_class: e.class.name)
        raise
      end

      private

      def run(source_id, subscription_id)
        return 'skipped_feature_disabled' unless Feature.enabled?

        source = ExternalSource.find_by(id: source_id)
        return 'skipped_source_missing' if source.nil?

        with_source_lock(source.id) do
          refresh_locked(source, subscription_id)
        end
      rescue Error => e
        record_failure(source_id, subscription_id, e.code)
      end

      def record(source_id, subscription_id, outcome, started, extra = {})
        fields = {
          source_id: source_id,
          subscription_id: subscription_id.presence || '-',
          outcome: outcome,
        }.merge(@fields || {}).merge(extra)
        fields[:elapsed_ms] = RefreshLog.elapsed_ms(started)
        RefreshLog.emit('refresh', fields)
        fields.merge(outcome: outcome)
      end

      def refresh_locked(source, subscription_id)
        permitted = active_permitted(source)
        accounted = accounted_subscriptions(permitted, subscription_id)
        @fields.merge!(accounted: accounted.size, offered: permitted.size - accounted.size)
        return skip_outcome(permitted, subscription_id) if accounted.empty?

        @stage = :fetch
        response = HttpClient.get(source.canonical_key, etag: source.etag, last_modified: source.last_modified)
        @fields[:http_status] = response.code
        if response.code == 304
          source.update!(checked_at: Time.current)
          resources = source.external_resources.order(published_at: :desc, id: :desc).limit(Limits::MAX_ITEMS).to_a
          @fields[:cached_items] = resources.size
          @stage = :ingest
          apply_resources(permitted, accounted, resources)
          'not_modified'
        elsif response.code.between?(200, 299)
          @stage = :parse
          feed = Parser.parse!(response.body)
          @stage = :ingest
          resources = Ingest.new.apply_public!(source, feed, response)
          @fields[:items] = resources.size
          apply_resources(permitted, accounted, resources)
          'fetched'
        else
          code = [401, 403].include?(response.code) ? 'authenticated_source_rejected' : "http_#{response.code}"
          @fields[:error_code] = RefreshLog.code(code)
          @fields[:failures] = mark_subscriptions(accounted, code).size
          'http_error'
        end
      end

      def skip_outcome(permitted, subscription_id)
        return 'skipped_no_permitted_subscriptions' if permitted.empty?

        subscription_id.present? ? 'skipped_inactive_subscription' : 'skipped_not_due'
      end

      def apply_resources(permitted, accounted, resources)
        materialize_accounted(accounted, resources)
        offer_shared_cache(permitted, accounted, resources)
      end

      def active_permitted(source)
        source.external_subscriptions.active.includes(:user).select { |subscription| Feature.permitted?(subscription.user) }
      end

      def accounted_subscriptions(permitted, subscription_id)
        if subscription_id.present?
          permitted.select { |subscription| subscription.id == subscription_id.to_i }
        else
          due_ids = ExternalSubscription.due_for_refresh.where(id: permitted.map(&:id)).ids
          permitted.select { |subscription| due_ids.include?(subscription.id) }
        end
      end

      def materialize_accounted(targets, resources)
        counts = { projected_ok: 0, projected_failed: 0, projected_skipped: 0, failures: 0 }
        targets.each do |subscription|
          result = Materialize.new.call(subscription: subscription, resources: resources, retries: true)
          SubscriptionOutcome.reconcile!(subscription, result) if result.ran
          counts[:projected_ok] += result.succeeded.to_i
          counts[:projected_failed] += result.failed.to_i
          counts[:projected_skipped] += result.skipped.to_i
        rescue StandardError => e
          counts[:failures] += 1
          Rails.logger.info("[ExternalBridge::RSS] subscriber refresh failed subscription=#{subscription.id} code=#{e.class}")
          SubscriptionOutcome.retry!(subscription, 'import_failed')
        end
        @fields.merge!(counts)
      end

      def offer_shared_cache(permitted, accounted, resources)
        accounted_ids = accounted.map(&:id)
        permitted.each do |subscription|
          next if accounted_ids.include?(subscription.id)

          Materialize.new.call(subscription: subscription, resources: resources, retries: false)
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] shared cache offer skipped subscription=#{subscription.id} code=#{e.class}")
        end
      end

      def mark_subscriptions(targets, code)
        targets.each do |subscription|
          SubscriptionOutcome.fetch_failure!(subscription, code)
        end
      end

      # The stage tells the log which step raised; the code is the fixed Error code.
      def record_failure(source_id, subscription_id, code)
        @fields[:error_code] = RefreshLog.code(code)
        outcome = { parse: 'parse_failed', ingest: 'import_failed', fetch: 'fetch_failed' }.fetch(@stage, 'refresh_failed')
        source = ExternalSource.find_by(id: source_id)
        return 'skipped_source_missing' if source.nil?

        permitted = active_permitted(source)
        @fields[:failures] = mark_subscriptions(accounted_subscriptions(permitted, subscription_id), code).size
        outcome
      end

      def with_source_lock(source_id)
        connection = ActiveRecord::Base.connection
        locked = connection.select_value(ActiveRecord::Base.sanitize_sql_array(['SELECT pg_try_advisory_lock(810531, ?)', source_id.to_i]))
        return 'skipped_lock_busy' unless locked == true || locked.to_s == 't'

        yield
      ensure
        if locked == true || locked.to_s == 't'
          connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT pg_advisory_unlock(810531, ?)', source_id.to_i]))
        end
      end
    end
  end
end
