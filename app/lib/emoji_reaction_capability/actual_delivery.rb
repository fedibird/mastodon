# frozen_string_literal: true

module EmojiReactionCapability
  # What EmojiReactionService delivers today, and the policy label for that
  # send. This is not DeliveryPlan. The proposal stays behind the P1b-1c
  # subflags, which are off, so a case where the proposal and the legacy
  # sender disagree is labeled unknown and is still sent as it is today.
  #
  # unknown is conservative: ask requires confirmation, deny is
  # capability_unknown_denied. allow keeps today's activity. A Like is never
  # labeled native. native is only an EmojiReact that is not a Q3 or Q7 case.
  module ActualDelivery
    LEGACY_NATIVE_TYPES = %w(unicode custom).freeze
    LEGACY_LIKE_SOFTWARE = %w(kmyblue).freeze
    NO_EFFECTS = [].freeze
    REMOTE_FAVOURITE = ['remote_favourite'].freeze

    Classification = Data.define(:activity_type, :mechanism, :basis, :effects, :audience)

    module_function

    # The choice create_notification used to inline. A missing node is not
    # the FEATURES default: nil&.features is nil, so the activity is Like.
    # A stored row whose info omits the key uses that default ('custom') and
    # is EmojiReact, unless software is exactly kmyblue.
    def legacy_remote_type(node)
      type = LEGACY_NATIVE_TYPES.include?(node&.features(:emoji_reaction_type)) ? 'EmojiReact' : 'Like'
      return 'Like' if LEGACY_LIKE_SOFTWARE.include?(node&.software)

      type
    end

    def classify(author, emoji_kind, node_row, snapshot)
      return build(nil, :not_delivered, :author_silenced, :none) if author.silenced?
      return build(nil, :native, :local_fanout, :followers_and_mentions) if author.local?
      return build(nil, :not_delivered, :not_activitypub, :none) unless author.activitypub?

      activity = legacy_remote_type(node_row)
      return build(activity, :unknown, :unknown_no_row, :author_inbox) if node_row.nil? || !snapshot.row_present
      return unknown_snapshot(activity, snapshot) if snapshot.nodeinfo_missing || snapshot.emoji_reaction_type == 'unknown'
      return build(activity, :like_fallback, :mechanism_override_like, :author_inbox) if LEGACY_LIKE_SOFTWARE.include?(node_row.software)
      return build(activity, :unknown, :unicode_only_custom, :author_inbox) if emoji_kind == :custom && node_row.features(:emoji_reaction_type) == 'unicode'
      return build(activity, :like_fallback, :like_fallback, :author_inbox) if activity == 'Like'

      build(activity, :native, :native, :author_inbox)
    end

    # Digest of the normalized snapshot and the legacy send. `stale` is left
    # out: it flips on the clock and does not change the gate.
    def state_digest(classification, snapshot, policy)
      payload = {
        'activity_type' => classification.activity_type,
        'basis' => classification.basis.to_s,
        'effects' => classification.effects,
        'mechanism' => classification.mechanism.to_s,
        'policy' => policy,
        'snapshot' => {
          'admin_override' => snapshot.admin_override,
          'emoji_reaction_type' => snapshot.emoji_reaction_type,
          'like_delivery' => snapshot.like_delivery.to_s,
          'max_per_account' => snapshot.max_per_account,
          'mechanism_override' => snapshot.mechanism_override&.to_s,
          'nodeinfo_missing' => snapshot.nodeinfo_missing,
          'reachability' => snapshot.reachability.to_s,
          'row_present' => snapshot.row_present,
          'software' => snapshot.software,
          'stale_info_ignored' => snapshot.stale_info_ignored,
          'type_source' => snapshot.type_source.to_s,
          'upstream' => snapshot.upstream,
        },
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def unknown_snapshot(activity, snapshot)
      basis = snapshot.nodeinfo_missing ? :unknown_nodeinfo_missing : :unknown_type
      build(activity, :unknown, basis, :author_inbox)
    end

    def build(activity_type, mechanism, basis, audience)
      effects = activity_type == 'Like' && %i(like_fallback unknown).include?(mechanism) ? REMOTE_FAVOURITE : NO_EFFECTS
      Classification.new(
        activity_type: activity_type,
        mechanism: mechanism,
        basis: basis,
        effects: effects,
        audience: audience
      )
    end
  end
end
