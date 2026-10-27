# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Due probe rows for one source. Explicit typed links come first.
      # Ordinary permalinks are limited to a stable id sample so a long
      # history is not walked two URLs at a time.
      #
      # The predicates match the partial indexes added with discovery:
      # index_external_resources_on_ap_probe_due,
      # index_external_resources_on_ap_sample, and
      # index_external_resources_on_ap_item_verified.
      class DueResources
        def initialize(source, now: Time.current)
          @source = source
          @now = now
        end

        def ids
          picked = explicit_ids
          return picked if picked.size >= Limits::MAX_GETS_PER_RUN || ordinary_blocked?

          picked + ordinary_ids(Limits::MAX_GETS_PER_RUN - picked.size)
        end

        def due?
          explicit_relation.exists? || (!ordinary_blocked? && ordinary_relation(1).exists?)
        end

        def sample_ids
          sample_scope.pluck(:id)
        end

        def explicit_probe_scope
          explicit_relation.order(:activitypub_next_check_at, :id).limit(Limits::MAX_GETS_PER_RUN)
        end

        def ordinary_probe_scope
          ordinary_relation(Limits::MAX_GETS_PER_RUN)
        end

        def self.verified_items(source)
          source.external_resources.where(activitypub_state: 'verified', source_deleted_at: nil)
        end

        private

        def explicit_ids
          explicit_probe_scope.pluck(:id)
        end

        def ordinary_ids(limit)
          return [] if limit <= 0

          ordinary_relation(limit).pluck(:id)
        end

        def base
          @source.external_resources.where(source_deleted_at: nil).where.not(activitypub_candidate_url: nil)
        end

        def explicit_relation
          base.where(activitypub_explicit: true).where('activitypub_next_check_at <= ?', @now)
        end

        def ordinary_relation(limit)
          base.where(activitypub_explicit: false, id: sample_scope.select(:id))
              .where('activitypub_next_check_at <= ?', @now)
              .order(:activitypub_next_check_at, :id)
              .limit(limit)
        end

        def sample_scope
          base.where(activitypub_explicit: false).order(:id).limit(sample_cap)
        end

        def sample_cap
          return Limits::CONFIRMED_HOST_SAMPLE_CAP if host_supported?

          Limits::ORDINARY_SAMPLE_CAP
        end

        def host_supported?
          ExternalSource.where(id: @source.id, host_activitypub_supported: ExternalSource::HOST_ACTIVITYPUB_SUPPORTED).exists?
        end

        def ordinary_blocked?
          ExternalSource.where(id: @source.id).where('activitypub_ordinary_blocked_until > ?', @now).exists?
        end
      end
    end
  end
end
