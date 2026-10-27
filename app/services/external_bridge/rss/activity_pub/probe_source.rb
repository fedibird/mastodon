# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # At most two public object GETs per source invocation, never per user.
      # A compare-and-set lease prevents concurrent workers from probing an
      # item twice and guards against a feed changing its URL during the GET.
      class ProbeSource
        MAX_PER_RUN = 2
        LEASE = 30.minutes
        RETRY_ERROR = 1.day
        RETRY_UNAVAILABLE = 7.days
        RETRY_VERIFIED = 7.days

        def call(source_id)
          return unless Schedule.enabled?

          source = ExternalSource.find_by(id: source_id)
          return if source.nil? || !Schedule.permitted_source?(source)

          probe_instance(source)
          due_resources(source).each { |id| probe_one(id) }
          Schedule.recompute_source!(source.reload)
        end

        private

        def probe_instance(source)
          now = Time.current
          claimed = ExternalSource.where(id: source.id)
                                  .where('activitypub_instance_next_check_at IS NULL OR activitypub_instance_next_check_at <= ?', now)
                                  .update_all(activitypub_instance_next_check_at: now + LEASE)
          return if claimed.zero?

          result = NodeInfoProbe.new.call(source.canonical_key)
          checked = Time.current
          delay = %w(error inaccessible).include?(result.state) ? RETRY_ERROR : RETRY_VERIFIED
          ExternalSource.where(id: source.id).update_all(
            activitypub_instance_state: result.state,
            activitypub_software: result.software,
            activitypub_instance_checked_at: checked,
            activitypub_instance_next_check_at: checked + delay
          )
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] NodeInfo probe failed source=#{source.id} code=#{e.class}")
        end

        def due_resources(source)
          source.external_resources
                .where(source_deleted_at: nil)
                .where.not(activitypub_candidate_url: nil)
                .where('activitypub_next_check_at IS NULL OR activitypub_next_check_at <= ?', Time.current)
                .order(published_at: :desc, id: :desc)
                .limit(MAX_PER_RUN)
                .pluck(:id)
        end

        def probe_one(id)
          now = Time.current
          claimed = ExternalResource.where(id: id, source_deleted_at: nil)
                                    .where('activitypub_next_check_at IS NULL OR activitypub_next_check_at <= ?', now)
                                    .where.not(activitypub_candidate_url: nil)
                                    .update_all(activitypub_next_check_at: now + LEASE)
          return if claimed.zero?

          resource = ExternalResource.find_by(id: id)
          return if resource.nil?

          candidate = resource.activitypub_candidate_url
          result = Probe.new.call(candidate)
          checked = Time.current
          delay = result.state == 'verified' ? RETRY_VERIFIED : (result.state == 'error' || result.state == 'inaccessible' ? RETRY_ERROR : RETRY_UNAVAILABLE)
          ExternalResource.where(id: id, activitypub_candidate_url: candidate).update_all(
            activitypub_state: result.state,
            activitypub_object_id: result.object_id,
            activitypub_object_type: result.object_type,
            activitypub_checked_at: checked,
            activitypub_next_check_at: checked + delay
          )
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] AP probe failed resource=#{id} code=#{e.class}")
          # The claim remains leased; the next feed pass retries after it expires.
        end
      end
    end
  end
end
