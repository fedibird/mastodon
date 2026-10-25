# frozen_string_literal: true

module EmojiReactionCapability
  # Pure comparison of the activity type the legacy code actually chose with
  # the proposed DeliveryPlan. Produces only bounded values.
  module ShadowComparator
    OPS = %w(create undo fanout_create fanout_delete).freeze
    TYPES = %w(EmojiReact Like none).freeze

    module_function

    # legacy_type: 'EmojiReact', 'Like' or nil (the legacy code sent nothing)
    # node: NodeSnapshot, or nil when the plan did not need a Node
    def compare(op:, kind:, legacy_type:, plan:, node: nil) # rubocop:disable Naming/MethodParameterName
      legacy = legacy_type || 'none'
      proposed = plan.activity_type || 'none'

      {
        op: op.to_s,
        kind: kind.to_s,
        family: node ? node.family : 'none',
        node: node ? node.state : 'not_read',
        legacy: legacy,
        proposed: proposed,
        basis: plan.basis.to_s,
        result: legacy == proposed ? 'match' : 'diff',
      }
    end

    # Human label for a diff, derived only from the bounded fields. Used by
    # the report; nothing here is stored.
    def reason(op:, legacy:, proposed:, basis:) # rubocop:disable Naming/MethodParameterName
      return 'match' if legacy == proposed

      case basis
      when 'unicode_only_custom' then 'unicode_only_node_custom_emoji'
      when 'unsupported_node', 'unsupported_gone' then 'proposed_refusal'
      when 'author_silenced' then op.to_s.start_with?('undo') ? 'undo_not_skipped_for_silenced' : 'silenced_local_only'
      when 'native' then op.to_s == 'undo' && legacy == 'Like' ? 'undo_asymmetry_native_sent_as_like' : 'native_vs_legacy_type'
      when /\Aunknown_/ then "unknown_node_#{basis.delete_prefix('unknown_')}"
      when 'mechanism_override_like', 'like_fallback' then 'like_vs_legacy_type'
      else 'type_mismatch'
      end
    end
  end
end
