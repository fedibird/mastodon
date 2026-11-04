# frozen_string_literal: true

module FeedDelivery
  # Collects the keyword rules already loaded for one destination.
  #
  # The first match is the reply qualification. Scanning continues until an
  # ignore-block match is found or the group ends. Finding no ignore-block
  # rule is not recorded: a later or excluded rule may still carry that flag,
  # and the worker must not treat the omission as a negative proof.
  module KeywordScan
    module_function

    def collect(subscribes, matching_text, status:)
      reply = nil
      ignore_block = nil

      subscribes.each do |subscribe|
        next if reply && !subscribe.ignore_block?
        next unless subscribe.match?(matching_text)

        reply ||= subscribe
        ignore_block ||= subscribe if subscribe.ignore_block?
        break if reply && ignore_block
      end

      return nil unless reply

      Evidence.build(subscription: reply, ignore_block_subscription: ignore_block, status: status)
    end
  end
end
