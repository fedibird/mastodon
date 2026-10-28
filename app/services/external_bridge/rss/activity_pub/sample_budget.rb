# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Chooses which permalinks are stored as probe candidates for one feed
      # write. Explicit ActivityStreams links are always kept.
      #
      # Ordinary links have two budgets. An unconfirmed feed keeps a small
      # exploration sample; a negative result pauses further ordinary URLs
      # until that cooldown ends. Once the feed is a fresh-item candidate
      # (NodeInfo support, a likely generator match, or any verified item),
      # checked rows stop occupying a slot and the next new permalinks can
      # be queued. The cap is on unchecked rows, not on the whole history.
      class SampleBudget
        Decision = Struct.new(:url, :explicit, keyword_init: true)

        def self.outstanding_ordinary(source)
          source.external_resources.where(
            source_deleted_at: nil,
            activitypub_explicit: false,
            activitypub_checked_at: nil
          ).where.not(activitypub_candidate_url: nil)
        end

        def initialize(source)
          @fresh = source.activitypub_fresh_items_allowed?
          @blocked = !@fresh && cooldown_active?(source)
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

          [cap_for - self.class.outstanding_ordinary(source).count, 0].max
        end

        def cap_for
          return Limits::CONFIRMED_HOST_SAMPLE_CAP if @fresh

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
          return unless occupying_slot?(resource)

          @remaining += 1
        end

        def occupying_slot?(resource)
          resource.persisted? && !resource.activitypub_explicit && resource.activitypub_candidate_url.present? && resource.activitypub_checked_at.nil?
        end
      end
    end
  end
end
