# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Due probe rows for one source. Explicit typed links come first.
      # Ordinary rows are the due index range, at most Limits::MAX_GETS_PER_RUN.
      # Unchecked rows use the epoch due time, so they sort ahead of retries.
      # Checked rows with a future next_check_at stay out of that range.
      #
      # The predicates match partial indexes:
      # index_external_resources_on_ap_probe_due and
      # index_external_resources_on_ap_item_verified.
      # Outstanding unchecked rows are counted through
      # index_external_resources_on_ap_unchecked.
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
          base.where(activitypub_explicit: false)
              .where('activitypub_next_check_at <= ?', @now)
              .order(:activitypub_next_check_at, :id)
              .limit(limit)
        end

        def ordinary_blocked?
          source = ExternalSource.find_by(id: @source.id)
          return false if source.nil?

          source.ordinary_activitypub_probe_blocked?(@now)
        end
      end
    end
  end
end
