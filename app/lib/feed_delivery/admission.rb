# frozen_string_literal: true

module FeedDelivery
  # Replaces KeywordSubscribe.match? inside the feed filters.
  #
  # off and any job without fresh evidence call the existing matcher. shadow
  # always calls it and only counts agreement. enforce trusts a fresh positive
  # qualification and otherwise uses the existing matcher, so one expired rule
  # does not drop a destination that another rule still matches.
  module Admission
    module_function

    def keyword_match?(status, account_id:, list_id:, crutches:, as_ignore_block: false)
      evidence = crutches[:delivery_evidence]
      return legacy_match(status, account_id, list_id, as_ignore_block) unless usable?(evidence)

      fresh = evidence.fresh_for?(status: status, account_id: account_id, list_id: list_id, as_ignore_block: as_ignore_block)
      return accept_evidence(as_ignore_block) if FeedDelivery.enforce? && fresh

      legacy = legacy_match(status, account_id, list_id, as_ignore_block)
      Metrics.record(metric_field(as_ignore_block, comparison_result(fresh, legacy))) if FeedDelivery.observe?
      legacy
    end

    def usable?(evidence)
      FeedDelivery.observe? && evidence.is_a?(Evidence) && evidence.keyword?
    end

    def accept_evidence(as_ignore_block)
      Metrics.record(metric_field(as_ignore_block, 'evidence'))
      true
    end

    def comparison_result(fresh, legacy)
      return 'fallback' unless fresh
      return 'agree' if legacy

      'disagree'
    end

    def metric_field(as_ignore_block, result)
      qualification = as_ignore_block ? 'ignore_block' : 'reply'
      "kw|qual=#{qualification}|result=#{result}"
    end

    def legacy_match(status, account_id, list_id, as_ignore_block)
      KeywordSubscribe.match?(status, account_id: account_id, list_id: list_id, as_ignore_block: as_ignore_block)
    end
  end
end
