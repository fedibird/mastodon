# frozen_string_literal: true

module EmojiReactionCapability
  # Pure rule: how would a reaction of one emoji kind reach this Node?
  # (docs/emoji_reaction_capability_resolver.md section 5.1.2, step 4)
  #
  # Returns [mechanism, basis]:
  #   mechanism: :native, :like_fallback, :unknown, :none
  #   basis:     one of DeliveryPlan::BASES
  #
  # Unknown is never treated as native (F3), and a missing key is unknown
  # rather than the legacy 'custom' default.
  module Mechanism
    KINDS = %i(unicode custom).freeze

    module_function

    def classify(node, kind)
      raise ArgumentError, "unknown emoji kind: #{kind.inspect}" unless KINDS.include?(kind)

      return [:none, :unsupported_gone] if node.reachability == :gone

      case native_path(node, kind)
      when :yes
        [:native, :native]
      when :unknown
        [:unknown, unknown_basis(node)]
      else
        non_native(node, kind)
      end
    end

    def native_path(node, kind)
      return :no if node.mechanism_override == :like_fallback

      case node.emoji_reaction_type
      when 'custom' then :yes
      when 'unicode' then kind == :unicode ? :yes : :no
      when 'none' then :no
      else :unknown
      end
    end

    def non_native(node, kind)
      case node.like_delivery
      when :accepts then [:like_fallback, fallback_basis(node, kind)]
      when :rejects then [:none, :unsupported_node]
      else [:unknown, unknown_basis(node)]
      end
    end

    def fallback_basis(node, kind)
      if node.mechanism_override == :like_fallback
        :mechanism_override_like
      elsif node.emoji_reaction_type == 'unicode' && kind == :custom
        :unicode_only_custom
      else
        :like_fallback
      end
    end

    def unknown_basis(node)
      if !node.row_present
        :unknown_no_row
      elsif node.type_source == :missing_nodeinfo
        :unknown_nodeinfo_missing
      elsif node.emoji_reaction_type == 'unknown'
        :unknown_type
      else
        :unknown_like_delivery
      end
    end
  end
end
