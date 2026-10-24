# frozen_string_literal: true

module ExternalBridge
  module Streaming
    # Private Redis channels. They are not client stream names.
    # Ids stay decimal strings so a value above 2^53 is not rounded.
    module Channels
      module_function

      def home(user_id)
        id = decimal_id(user_id)
        return nil if id.nil?

        "timeline:external:user:#{id}:home"
      end

      def list(user_id, list_id)
        user = decimal_id(user_id)
        list = decimal_id(list_id)
        return nil if user.nil? || list.nil?

        "timeline:external:user:#{user}:list:#{list}"
      end

      def control(user_id)
        id = decimal_id(user_id)
        return nil if id.nil?

        "timeline:external:user:#{id}:control"
      end

      # E4 share state of the owner's projections. Not an E3 route channel, so
      # it needs no feed route and no E3 flag. Only the token user's own pair is
      # ever published here.
      def boost(user_id)
        id = decimal_id(user_id)
        return nil if id.nil?

        "timeline:external:user:#{id}:boost"
      end

      def decimal_id(value)
        text = value.to_s
        return nil unless text.match?(/\A[1-9]\d*\z/)

        text
      end

      def revision_text(value)
        text = value.to_s
        return nil unless text.match?(/\A(?:0|[1-9]\d*)\z/)

        text
      end
    end
  end
end
