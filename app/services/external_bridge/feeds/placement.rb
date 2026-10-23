# frozen_string_literal: true

module ExternalBridge
  module Feeds
    # Classifies a bounded id set for one owner and one home or list.
    #
    # Ordinary ids that are outside the Redis window stay out of this result.
    # Only rows with this user's projection marker are classified from the
    # database. One marker read and, when delivery is on, one eligibility
    # read cover the whole set. Neither walks the feed.
    class Placement
      Partition = Struct.new(:members, :withheld, :deferred, keyword_init: true)

      def self.empty
        Partition.new(members: Set.new, withheld: Set.new, deferred: Set.new)
      end

      def initialize(user:, destination:, list: nil, visibilities: nil, regenerating: false)
        @user = user
        @destination = destination.to_s
        @list = list
        @visibilities = visibilities
        @regenerating = regenerating
      end

      def partition(status_ids)
        return self.class.empty if @user.nil?

        wanted = Array(status_ids).filter_map { |value| integer_id(value) }.uniq
        return self.class.empty if wanted.empty?

        owned = owned_ids(wanted)
        return self.class.empty if owned.empty?

        eligible = eligible_ids(owned)
        withheld = owned - eligible
        if @regenerating
          Partition.new(members: Set.new, withheld: withheld.to_set, deferred: eligible.to_set)
        else
          Partition.new(members: eligible.to_set, withheld: withheld.to_set, deferred: Set.new)
        end
      end

      private

      def eligible_ids(owned)
        return [] unless deliver?

        Query.new(user: @user, destination: @destination, list: @list).eligible_ids(owned)
      end

      # Empty visibilities match a home or list read that did not filter.
      # An explicit list that omits external keeps those rows out of the view.
      # The delivery flag still has to permit this user. A home rebuild does
      # not make an eligible row a member of the unfinished Redis range.
      def deliver?
        return false unless Feature.permitted?(@user)
        return false unless @destination == Query::HOME || @destination == Query::LIST
        return false if @destination == Query::LIST && (@list.nil? || @list.account_id != @user.account_id)

        values = Array(@visibilities).map { |value| value.to_s.strip }.reject(&:empty?)
        values.empty? || values.include?('external')
      end

      def owned_ids(wanted)
        ExternalStatusProjection.where(user_id: @user.id, status_id: wanted).pluck(:status_id)
      end

      def integer_id(value)
        TimelineSeek::StatusId.parse(value)
      end
    end
  end
end
