# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # At most Limits::MAX_GETS_PER_RUN public object GETs per source run.
      # The claim bumps activitypub_evidence_version and the completion
      # updates only that version plus the candidate digest, so a feed write
      # that replaced the URL cannot keep this result.
      class ProbeSource
        Snapshot = Struct.new(:id, :url, :digest, :version, :explicit, :source_id, keyword_init: true)

        def call(source_id)
          return unless Schedule.enabled?

          source = ExternalSource.find_by(id: source_id)
          return if source.nil? || !Schedule.permitted_source?(source)

          probe_instance(source)
          DueResources.new(source.reload).ids.each { |id| probe_one(id) }
          Schedule.recompute_source!(source)
        end

        private

        def probe_instance(source)
          now = Time.current
          claimed = ExternalSource.where(id: source.id)
                                  .where('activitypub_instance_next_check_at IS NULL OR activitypub_instance_next_check_at <= ?', now)
                                  .update_all(activitypub_instance_next_check_at: now + Limits::LEASE)
          return if claimed.zero?

          result = NodeInfoProbe.new.call(source.canonical_key)
          checked = Time.current
          delay = %w(error inaccessible).include?(result.state) ? Limits::RETRY_ERROR : Limits::RETRY_VERIFIED
          ExternalSource.where(id: source.id).update_all(instance_attributes(result, checked, delay))
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] NodeInfo probe failed source=#{source.id} code=#{e.class}")
        end

        def instance_attributes(result, checked, delay)
          attributes = {
            activitypub_instance_state: result.state,
            activitypub_instance_checked_at: checked,
            activitypub_instance_next_check_at: checked + delay,
          }
          attributes[:activitypub_software] = result.software if result.state == 'advertised'
          attributes[:host_activitypub_supported] = host_support_for(result.state) if host_support_for(result.state)
          attributes
        end

        def host_support_for(state)
          case state
          when 'advertised' then ExternalSource::HOST_ACTIVITYPUB_SUPPORTED
          when 'not_advertised' then ExternalSource::HOST_ACTIVITYPUB_NOT_ADVERTISED
          end
        end

        def probe_one(id)
          resource = ExternalResource.find_by(id: id, source_deleted_at: nil)
          return if resource.nil?

          snapshot = snapshot_for(resource)
          return if snapshot.url.blank?
          # The id list was chosen before this run's first result. An ordinary
          # miss sets the cooldown immediately, and the next ordinary row in
          # that same list must not be fetched.
          return if ordinary_stopped?(snapshot)

          before_probe_claim(resource)
          lease_until = Time.current + Limits::LEASE
          return if claim!(snapshot, lease_until).zero?

          before_probe_commit(resource)
          result = Probe.new.call(snapshot.url)
          checked = Time.current
          written = commit_probe!(snapshot, result, checked)
          note_ordinary!(snapshot, result, checked) if written == 1
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] AP probe failed resource=#{id} code=#{e.class}")
        end

        def snapshot_for(resource)
          Snapshot.new(
            id: resource.id,
            url: resource.activitypub_candidate_url,
            digest: resource.activitypub_candidate_digest,
            version: resource.activitypub_evidence_version.to_i,
            explicit: resource.activitypub_explicit,
            source_id: resource.external_source_id
          )
        end

        def claim!(snapshot, lease_until)
          ExternalResource.where(claim_identity(snapshot))
                          .where('activitypub_next_check_at IS NULL OR activitypub_next_check_at <= ?', Time.current)
                          .update_all(activitypub_next_check_at: lease_until, activitypub_evidence_version: snapshot.version + 1)
        end

        def commit_probe!(snapshot, result, checked)
          verified = result.state == 'verified'
          ExternalResource.where(claim_identity(snapshot).merge(activitypub_evidence_version: snapshot.version + 1)).update_all(
            activitypub_state: result.state,
            activitypub_object_id: verified ? result.object_id : nil,
            activitypub_object_id_status: verified ? ExternalResource::OBJECT_ID_SELF_REPORTED : nil,
            activitypub_object_type: verified ? result.object_type : nil,
            activitypub_checked_at: checked,
            activitypub_next_check_at: checked + delay_for(result),
            activitypub_evidence_version: snapshot.version + 2
          )
        end

        def claim_identity(snapshot)
          {
            id: snapshot.id,
            source_deleted_at: nil,
            activitypub_candidate_url: snapshot.url,
            activitypub_candidate_digest: snapshot.digest,
            activitypub_evidence_version: snapshot.version,
          }
        end

        def delay_for(result)
          case result.state
          when 'verified' then Limits::RETRY_VERIFIED
          when 'error', 'inaccessible' then Limits::RETRY_ERROR
          else Limits::RETRY_UNAVAILABLE
          end
        end

        def ordinary_stopped?(snapshot)
          return false if snapshot.explicit

          source = ExternalSource.find_by(id: snapshot.source_id)
          source.nil? || source.ordinary_activitypub_probe_blocked?
        end

        def note_ordinary!(snapshot, result, checked)
          return if snapshot.explicit
          # 401/403 stays inaccessible on the resource. It still pauses
          # ordinary exploration on an unconfirmed feed. It does not mean
          # the server has no ActivityPub.
          return unless %w(unavailable error inaccessible).include?(result.state)

          source = ExternalSource.find_by(id: snapshot.source_id)
          return if source.nil? || source.activitypub_fresh_items_allowed?

          until_at = checked + Limits::NEGATIVE_COOLDOWN
          ExternalSource.where(id: snapshot.source_id)
                        .where('activitypub_ordinary_blocked_until IS NULL OR activitypub_ordinary_blocked_until < ?', until_at)
                        .update_all(activitypub_ordinary_blocked_until: until_at)
        end

        # Test seam. The candidate snapshot is already in memory. A feed write
        # can commit a new URL before claim! and the digest predicate drops it.
        def before_probe_claim(_resource)
          nil
        end

        # Test seam. The lease version is already stored. Completion still
        # requires that version and the original digest.
        def before_probe_commit(_resource)
          nil
        end
      end
    end
  end
end
