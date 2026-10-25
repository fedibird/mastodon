# frozen_string_literal: true

module EmojiReactionCapability
  # Pure decision core. No database, Redis, network, clock or global read:
  # everything arrives in an Input. Used only by shadow mode in P1a; no write
  # path consults it.
  #
  # Decision order (docs/emoji_reaction_capability_resolver.md section 5.1.2):
  #   1. hard blocks (disabled)           shared by both kinds
  #   2. unsupported                      per kind
  #   3. fallback policy deny, then limit per kind
  #   4. mechanism and consent            per kind
  module Resolver
    KINDS = Mechanism::KINDS
    AGGREGATE_ORDER = %w(allowed unknown confirm limit_reached disabled unsupported).freeze

    module_function

    def call(input)
      kinds = KINDS.index_with { |kind| call_kind(input, kind) }
      aggregate(input, kinds)
    end

    def call_many(inputs)
      inputs.map { |input| call(input) }
    end

    def call_kind(input, kind)
      raise ArgumentError, "unknown emoji kind: #{kind.inspect}" unless KINDS.include?(kind)

      plan = DeliveryPlan.for_status(input.status, input.node, kind)

      if (reason = hard_block(input))
        return build_kind(kind, :none, 'disabled', reason, plan: plan)
      end

      mechanism = mechanism_for(input, kind)
      return build_kind(kind, :none, 'unsupported', 'node_unsupported', plan: plan) if mechanism == :none

      limit = limit_for(input, mechanism)
      effects = %i(like_fallback unknown).include?(mechanism) ? %w(remote_favourite) : []
      policy = input.viewer.fallback_policy

      if %i(like_fallback unknown).include?(mechanism) && policy == :deny
        reason = mechanism == :unknown ? 'capability_unknown_denied' : 'fallback_denied'
        return build_kind(kind, mechanism, 'disabled', reason, effects: effects, limit: limit, plan: plan)
      end

      if limit&.dig(:remaining)&.zero?
        reason = limit[:local_remaining]&.zero? ? 'limit_reached_local' : 'limit_reached_target'
        return build_kind(kind, mechanism, 'limit_reached', reason, effects: effects, limit: limit, plan: plan)
      end

      if mechanism == :native
        build_kind(kind, mechanism, 'allowed', nil, limit: limit, plan: plan)
      elsif policy == :ask
        build_kind(kind, mechanism, 'confirm', nil, can_add: true, requires_confirmation: true, effects: effects, limit: limit, plan: plan)
      else
        build_kind(kind, mechanism, mechanism == :unknown ? 'unknown' : 'allowed', nil, effects: effects, limit: limit, plan: plan)
      end
    end

    def mechanism_for(input, kind)
      status = input.status
      return :native if status.author_local
      return :none unless status.author_activitypub

      Mechanism.classify(input.node, kind).first
    end

    def hard_block(input)
      status = input.status

      if input.viewer.disable_reactions then 'viewer_reactions_disabled'
      elsif status.external_projection then 'external_content'
      elsif status.author_suspended then 'account_unavailable'
      elsif status.blocked_by_author || status.viewer_blocks_author then 'blocked_by_author'
      elsif status.viewer_blocks_domain || status.domain_rejected then 'domain_blocked'
      elsif status.status_override == :forbid then 'status_disallowed'
      end
    end

    # Local cap shared by both kinds, plus the native target limit for a native
    # kind only. Every value is nil when it was not read or is not known; a
    # missing value never produces a refusal.
    def limit_for(input, mechanism)
      counts = input.counts
      local_remaining = local_remaining(input)

      target_max = mechanism == :native && !input.status.author_local ? input.node.max_per_account : nil
      target_current = target_max && counts.unknown&.zero? ? counts.native : nil
      target_remaining = target_max && target_current ? [target_max - target_current, 0].max : nil

      {
        local_max: input.site.local_max,
        current: counts.total,
        local_remaining: local_remaining,
        target_max: target_max,
        target_current: target_current,
        target_remaining: target_remaining,
        remaining: [local_remaining, target_remaining].compact.min,
        target_limit_known: !target_remaining.nil?,
      }
    end

    def local_remaining(input)
      local_max = input.site.local_max
      total = input.counts.total
      local_max && total ? [local_max - total, 0].max : nil
    end

    def aggregate(input, kinds)
      best = kinds.values.min_by { |kind| AGGREGATE_ORDER.index(kind.availability) }
      addable = kinds.values.select(&:can_add)

      Decision.new(
        availability: best.availability,
        can_add: addable.any?,
        requires_confirmation: addable.any? && addable.none? { |kind| !kind.requires_confirmation },
        reason: best.reason,
        can_remove: input.counts.total.to_i.positive?,
        limit: { local_max: input.site.local_max, current: input.counts.total, local_remaining: local_remaining(input) },
        kinds: kinds
      )
    end

    def build_kind(kind, mechanism, availability, reason, plan:, can_add: nil, requires_confirmation: false, effects: [], limit: nil) # rubocop:disable Metrics/ParameterLists
      can_add = %w(allowed unknown confirm).include?(availability) if can_add.nil?

      KindDecision.new(
        kind: kind,
        mechanism: mechanism,
        availability: availability,
        can_add: can_add,
        requires_confirmation: requires_confirmation,
        reason: reason,
        effects: effects,
        limit: limit,
        plan: plan
      )
    end
  end
end
