# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Chooses which permalinks are stored as probe candidates for one feed
      # write. Explicit ActivityStreams links are always kept. Ordinary links
      # fill a small per-feed sample. Replacing the URL already in a sample
      # slot does not open another slot.
      class SampleBudget
        Decision = Struct.new(:url, :explicit, keyword_init: true)

        def initialize(source)
          @blocked = cooldown_active?(source)
          @remaining = remaining_slots(source)
          @decisions = {}
        end

        def decide(item_key, resource, item)
          return @decisions[item_key] if @decisions.key?(item_key)

          @decisions[item_key] = compute(resource, item)
        end

        private

        def cooldown_active?(source)
          until_at = source.activitypub_ordinary_blocked_until
          until_at.present? && until_at > Time.current
        end

        def remaining_slots(source)
          return 0 if @blocked

          used = source.external_resources.where(source_deleted_at: nil, activitypub_explicit: false).where.not(activitypub_candidate_url: nil).count
          [cap_for(source) - used, 0].max
        end

        def cap_for(source)
          return Limits::CONFIRMED_HOST_SAMPLE_CAP if source.host_reports_activitypub?

          Limits::ORDINARY_SAMPLE_CAP
        end

        def compute(resource, item)
          if item.activitypub_explicit && item.activitypub_url.present?
            release_ordinary_slot!(resource)
            return Decision.new(url: item.activitypub_url, explicit: true)
          end

          url = item.activitypub_sample_url
          return Decision.new(url: url, explicit: false) if holding_same_url?(resource, url)

          release_ordinary_slot!(resource)
          return Decision.new(url: nil, explicit: false) if url.blank? || @blocked || @remaining <= 0

          @remaining -= 1
          Decision.new(url: url, explicit: false)
        end

        def holding_same_url?(resource, url)
          resource.persisted? && !resource.activitypub_explicit && url.present? && resource.activitypub_candidate_url == url
        end

        def release_ordinary_slot!(resource)
          return unless resource.persisted?
          return if resource.activitypub_explicit || resource.activitypub_candidate_url.blank?

          @remaining += 1
        end
      end
    end
  end
end
