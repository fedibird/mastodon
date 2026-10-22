# frozen_string_literal: true

module ExternalBridge
  module Feeds
    # Merges ordinary feed ids with external membership ids, then hydrates
    # one page. Neither source is fully loaded as records before the limit.
    # A home feed that is regenerating stays on the ordinary read so an
    # external id cannot advance the cursor through an unfinished rebuild.
    class Compose
      def initialize(user:, feed:, destination:, list: nil)
        @user = user
        @feed = feed
        @destination = destination.to_s
        @list = list
      end

      def call(limit, max_id = nil, since_id = nil, min_id = nil, visibilities = [])
        visibilities = Array(visibilities)
        return @feed.get(limit, max_id, since_id, min_id, visibilities) unless merge?(visibilities)

        limit = limit.to_i
        return [] if limit <= 0

        scan = @feed.candidate_scan(limit, max_id, since_id, min_id, visibilities)
        external_ids = external_ids_for(scan, limit, max_id, since_id, min_id)
        merged = merge_ids(scan.ids, external_ids, limit, scan.ascending)
        merged.reverse! if scan.ascending
        hydrate(merged, scan.ids, visibilities)
      end

      private

      def merge?(visibilities)
        return false if @user.nil?
        return false unless Feature.permitted?(@user)
        return false unless @destination == Query::HOME || @destination == Query::LIST
        return false if @feed.is_a?(HomeFeed) && @feed.regenerating?
        return false unless external_requested?(visibilities)
        return false if @destination == Query::LIST && (@list.nil? || @list.account_id != @user.account_id)

        true
      end

      def external_requested?(visibilities)
        values = visibilities.map { |value| value.to_s.strip }
        values.empty? || values.include?('external')
      end

      def external_ids_for(scan, limit, max_id, since_id, min_id)
        return [] if !scan.exhausted && scan.frontier_id.nil?

        bounds = bounds_for(scan, max_id, since_id, min_id)
        Query.new(user: @user, destination: @destination, list: @list).ids(
          limit: limit,
          ascending: scan.ascending,
          **bounds
        )
      end

      def bounds_for(scan, max_id, since_id, min_id)
        max_id = integer_param(max_id)
        since_id = integer_param(since_id)
        min_id = integer_param(min_id)
        if scan.ascending
          {
            lower_exclusive: min_id,
            upper_exclusive: max_id,
            lower_inclusive: nil,
            upper_inclusive: scan.exhausted ? nil : scan.frontier_id,
          }
        else
          {
            lower_exclusive: since_id,
            upper_exclusive: max_id,
            lower_inclusive: scan.exhausted ? nil : scan.frontier_id,
            upper_inclusive: nil,
          }
        end
      end

      def integer_param(value)
        return nil if value.blank?

        value.to_i
      end

      def merge_ids(ordinary_ids, external_ids, limit, ascending)
        merged = []
        seen = {}
        left = 0
        right = 0
        while merged.size < limit && (left < ordinary_ids.size || right < external_ids.size)
          pick = pick_id(ordinary_ids, external_ids, left, right, ascending)
          if left < ordinary_ids.size && ordinary_ids[left] == pick
            left += 1
          end
          if right < external_ids.size && external_ids[right] == pick
            right += 1
          end
          next if seen[pick]

          seen[pick] = true
          merged << pick
        end
        merged
      end

      def pick_id(ordinary_ids, external_ids, left, right, ascending)
        return external_ids[right] if left >= ordinary_ids.size
        return ordinary_ids[left] if right >= external_ids.size

        first = ordinary_ids[left]
        second = external_ids[right]
        prefer_first = ascending ? first < second : first > second
        prefer_first ? first : second
      end

      def hydrate(ordered_ids, ordinary_scan_ids, visibilities)
        return [] if ordered_ids.empty?

        ordinary_ids = ordered_ids & ordinary_scan_ids
        external_ids = ordered_ids - ordinary_ids
        records = {}
        @feed.records_for(ordinary_ids, visibilities).each { |status| records[status.id] = status } if ordinary_ids.any?

        if external_ids.any?
          visible = Query.new(user: @user, destination: @destination, list: @list).eligible_ids(external_ids)
          Status.where(id: visible).each { |status| records[status.id] = status } if visible.any?
        end

        ordered = ordered_ids.filter_map { |id| records[id] }
        external_records = ordered.select { |status| status.external_projection == true || status.external_visibility? }
        return ordered if external_records.empty?

        ActiveRecord::Associations::Preloader.new.preload(
          external_records,
          external_status_projection: { external_resource: :external_source }
        )
        ProjectionAccess.prepare!(external_records)
        ordered.select { |status| visible_record?(status) }
      end

      def visible_record?(status)
        return true unless ProjectionPrivacy.private_status?(status)

        ProjectionAccess.allow?(@user.id, status)
      end
    end
  end
end
