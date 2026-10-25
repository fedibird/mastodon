# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmojiReactionCapability::Resolver do
  include EmojiReactionCapability

  let(:now) { Time.utc(2026, 10, 25, 12, 0, 0) }

  OPTION_KEYS = %i(override missing status).freeze

  # node('emoji_reaction_type' => 'custom') and node({ ... }, missing: true) both work.
  def node(info = {}, **options)
    raw_info, opts = options.partition { |key, _| !OPTION_KEYS.include?(key) }.map(&:to_h)
    EmojiReactionCapability::NodeSnapshot.from_attributes(
      info: info.merge(raw_info),
      info_override: opts[:override],
      nodeinfo_missing: opts.fetch(:missing, false),
      status: opts.fetch(:status, 'up'),
      last_fetched_at: now,
      now: now
    )
  end

  def status_context(**attrs)
    EmojiReactionCapability::StatusContext.new(**attrs)
  end

  def input(node:, status: {}, viewer: {}, counts: nil, local_max: nil)
    EmojiReactionCapability::Input.new(
      status: status_context(**status),
      node: node,
      viewer: EmojiReactionCapability::Viewer.new(**viewer),
      counts: counts || EmojiReactionCapability::Counts.unavailable,
      site: EmojiReactionCapability::SiteLimits.new(local_max: local_max)
    )
  end

  def counts(total, native, unknown)
    EmojiReactionCapability::Counts.new(total: total, native: native, unknown: unknown)
  end

  def kind_of(input, kind)
    described_class.call_kind(input, kind)
  end

  describe 'purity' do
    it 'issues no SQL and no Redis call' do
      sqls = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*args| sqls << args.last[:sql] }
      expect(RedisConfiguration).not_to receive(:with)

      described_class.call(input(node: node('emoji_reaction_type' => 'custom'), counts: counts(1, 1, 0), local_max: 3))

      expect(sqls).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'call_many equals mapping call' do
      inputs = [node('emoji_reaction_type' => 'custom'), node, EmojiReactionCapability::NodeSnapshot.absent].map { |n| input(node: n) }

      expect(described_class.call_many(inputs)).to eq inputs.map { |i| described_class.call(i) }
    end
  end

  describe 'mechanism and delivery plan per kind' do
    # [description, node info, kind, mechanism, activity_type, basis]
    [
      ['custom node, unicode emoji',        { 'emoji_reaction_type' => 'custom' },                                :unicode, :native,        'EmojiReact', :native],
      ['custom node, custom emoji',         { 'emoji_reaction_type' => 'custom' },                                :custom,  :native,        'EmojiReact', :native],
      ['unicode node, unicode emoji',       { 'emoji_reaction_type' => 'unicode' },                               :unicode, :native,        'EmojiReact', :native],
      ['unicode node, custom emoji, like accepted', { 'emoji_reaction_type' => 'unicode', 'favourite' => true }, :custom,  :like_fallback, 'Like',       :unicode_only_custom],
      ['unicode node, custom emoji, like unknown',  { 'emoji_reaction_type' => 'unicode' },                      :custom,  :unknown,       'Like',       :unknown_like_delivery],
      ['unicode node, custom emoji, like rejected', { 'emoji_reaction_type' => 'unicode', 'favourite' => 'none' }, :custom, :none,          nil,          :unsupported_node],
      ['none node, like accepted',          { 'emoji_reaction_type' => 'none', 'favourite' => true },             :unicode, :like_fallback, 'Like',       :like_fallback],
      ['none node, like false (H5)',        { 'emoji_reaction_type' => 'none', 'favourite' => false },            :unicode, :unknown,       'Like',       :unknown_like_delivery],
      ['none node, like absent (H5)',       { 'emoji_reaction_type' => 'none' },                                  :custom,  :unknown,       'Like',       :unknown_like_delivery],
      ['birdsitelive as produced by UpdateNodeService', { 'emoji_reaction_type' => 'none', 'emoji_reaction_max' => 0, 'favourite' => 'none', 'upstream_name' => 'birdsitelive' }, :unicode, :none, nil, :unsupported_node],
      ['misskey family',                    { 'emoji_reaction_type' => 'custom', 'favourite' => false, 'upstream_name' => 'misskey' }, :custom, :native, 'EmojiReact', :native],
      ['kmyblue',                           { 'emoji_reaction_type' => 'custom', 'favourite' => true, 'software_name' => 'kmyblue' }, :unicode, :like_fallback, 'Like', :mechanism_override_like],
      ['kmyblue with like absent',          { 'emoji_reaction_type' => 'custom', 'software_name' => 'kmyblue' },  :custom,  :unknown,       'Like',       :unknown_like_delivery],
      ['empty info (type key absent)',      {},                                                                   :unicode, :unknown,       'Like',       :unknown_type],
      ['type nil',                          { 'emoji_reaction_type' => nil },                                     :custom,  :unknown,       'Like',       :unknown_type],
    ].each do |description, info, kind, mechanism, activity_type, basis|
      it "#{description}: #{kind} is #{mechanism}" do
        decision = kind_of(input(node: node(info)), kind)

        expect(decision.mechanism).to eq mechanism
        expect(decision.plan.activity_type).to eq activity_type
        expect(decision.plan.basis).to eq basis
        expect(decision.plan.audience).to eq :author_inbox
      end
    end

    it 'treats NodeInfo missing as unknown even with a stale custom value' do
      decision = kind_of(input(node: node({ 'emoji_reaction_type' => 'custom' }, missing: true)), :unicode)

      expect(decision.mechanism).to eq :unknown
      expect(decision.plan).to have_attributes(activity_type: 'Like', basis: :unknown_nodeinfo_missing)
    end

    it 'uses an admin override when NodeInfo is missing' do
      decision = kind_of(input(node: node({}, override: { 'emoji_reaction_type' => 'custom' }, missing: true)), :unicode)

      expect(decision.mechanism).to eq :native
    end

    it 'treats an absent Node row as unknown' do
      decision = kind_of(input(node: EmojiReactionCapability::NodeSnapshot.absent), :custom)

      expect(decision.plan).to have_attributes(activity_type: 'Like', basis: :unknown_no_row)
    end

    it 'treats a gone Node as unsupported' do
      decision = kind_of(input(node: node({ 'emoji_reaction_type' => 'custom' }, status: 'gone')), :unicode)

      expect(decision).to have_attributes(availability: 'unsupported', reason: 'node_unsupported', can_add: false)
      expect(decision.plan).to have_attributes(activity_type: nil, basis: :unsupported_gone)
    end

    it 'computes unicode and custom independently on one Node' do
      decision = described_class.call(input(node: node({ 'emoji_reaction_type' => 'unicode', 'favourite' => true })))

      expect(decision.kinds[:unicode].mechanism).to eq :native
      expect(decision.kinds[:custom].mechanism).to eq :like_fallback
      expect(decision.kinds[:custom].effects).to eq %w(remote_favourite)
      expect(decision.kinds[:unicode].effects).to eq []
    end

    it 'rejects an unknown kind' do
      expect { described_class.call_kind(input(node: node), :sticker) }.to raise_error(ArgumentError)
    end
  end

  describe 'plan for author conditions' do
    let(:custom_node) { node('emoji_reaction_type' => 'custom') }

    it 'sends nothing to a silenced author' do
      plan = kind_of(input(node: custom_node, status: { author_silenced: true }), :unicode).plan

      expect(plan).to have_attributes(activity_type: nil, audience: :none, basis: :author_silenced)
    end

    it 'fans out for a local author with a type chosen per receiving Node' do
      decision = kind_of(input(node: custom_node, status: { author_local: true }), :unicode)

      expect(decision).to have_attributes(mechanism: :native, availability: 'allowed', effects: [])
      expect(decision.plan).to have_attributes(activity_type: nil, audience: :followers_and_mentions, basis: :local_fanout)
    end

    it 'sends nothing to a non-ActivityPub author and calls it unsupported' do
      decision = kind_of(input(node: custom_node, status: { author_activitypub: false }), :custom)

      expect(decision).to have_attributes(availability: 'unsupported')
      expect(decision.plan).to have_attributes(activity_type: nil, basis: :not_activitypub)
    end

    it 'plans per receiving Node for fan-out' do
      plan = EmojiReactionCapability::DeliveryPlan.for_node(node({ 'emoji_reaction_type' => 'unicode' }), :unicode)

      expect(plan).to have_attributes(activity_type: 'EmojiReact', audience: :receiver_inbox)
    end
  end

  describe 'decision order' do
    let(:custom_node) { node('emoji_reaction_type' => 'custom') }
    let(:gone_node) { node({ 'emoji_reaction_type' => 'custom' }, status: 'gone') }

    {
      { viewer: { disable_reactions: true } } => 'viewer_reactions_disabled',
      { status: { external_projection: true } } => 'external_content',
      { status: { author_suspended: true } } => 'account_unavailable',
      { status: { blocked_by_author: true } } => 'blocked_by_author',
      { status: { viewer_blocks_author: true } } => 'blocked_by_author',
      { status: { viewer_blocks_domain: true } } => 'domain_blocked',
      { status: { domain_rejected: true } } => 'domain_blocked',
      { status: { status_override: :forbid } } => 'status_disallowed',
    }.each do |attrs, reason|
      it "disables with #{reason} for #{attrs}" do
        decision = described_class.call(input(node: custom_node, **attrs))

        expect(decision).to have_attributes(availability: 'disabled', reason: reason, can_add: false)
        expect(decision.kinds.values).to all(have_attributes(availability: 'disabled', reason: reason))
      end
    end

    it 'ranks disabled above unsupported above limit_reached above policy' do
      full = counts(3, 3, 0)

      expect(kind_of(input(node: gone_node, viewer: { disable_reactions: true }, counts: full, local_max: 3), :unicode).availability).to eq 'disabled'
      expect(kind_of(input(node: gone_node, counts: full, local_max: 3), :unicode).availability).to eq 'unsupported'
      expect(kind_of(input(node: custom_node, counts: full, local_max: 3), :unicode).availability).to eq 'limit_reached'
      expect(kind_of(input(node: custom_node, counts: counts(0, 0, 0), local_max: 3), :unicode).availability).to eq 'allowed'
    end

    it 'keeps the delivery plan independent of blocks, limits and settings' do
      blocked = kind_of(input(node: custom_node, viewer: { disable_reactions: true }, counts: counts(3, 3, 0), local_max: 3), :unicode)

      expect(blocked.plan.activity_type).to eq 'EmojiReact'
    end
  end

  describe 'fallback policy as a pure input' do
    let(:fallback_node) { node('emoji_reaction_type' => 'none', 'favourite' => true) }
    let(:unknown_node) { node({}) }

    it 'allow: like_fallback is allowed, unknown is unknown' do
      expect(kind_of(input(node: fallback_node), :unicode)).to have_attributes(availability: 'allowed', can_add: true, requires_confirmation: false)
      expect(kind_of(input(node: unknown_node), :unicode)).to have_attributes(availability: 'unknown', can_add: true, requires_confirmation: false)
    end

    it 'ask: both need confirmation' do
      expect(kind_of(input(node: fallback_node, viewer: { fallback_policy: :ask }), :unicode)).to have_attributes(availability: 'confirm', can_add: true, requires_confirmation: true)
      expect(kind_of(input(node: unknown_node, viewer: { fallback_policy: :ask }), :unicode)).to have_attributes(availability: 'confirm', can_add: true, requires_confirmation: true)
    end

    it 'deny: both are disabled with the matching reason' do
      expect(kind_of(input(node: fallback_node, viewer: { fallback_policy: :deny }), :unicode)).to have_attributes(availability: 'disabled', reason: 'fallback_denied', can_add: false)
      expect(kind_of(input(node: unknown_node, viewer: { fallback_policy: :deny }), :unicode)).to have_attributes(availability: 'disabled', reason: 'capability_unknown_denied', can_add: false)
    end

    it 'never applies the policy to native' do
      native = node('emoji_reaction_type' => 'custom')

      %i(allow ask deny).each do |policy|
        expect(kind_of(input(node: native, viewer: { fallback_policy: policy }), :unicode)).to have_attributes(availability: 'allowed', can_add: true)
      end
    end

    it 'mixed kinds: deny refuses custom and keeps unicode usable (M4)' do
      decision = described_class.call(input(node: node('emoji_reaction_type' => 'unicode', 'favourite' => true), viewer: { fallback_policy: :deny }))

      expect(decision.kinds[:unicode]).to have_attributes(availability: 'allowed', can_add: true)
      expect(decision.kinds[:custom]).to have_attributes(availability: 'disabled', reason: 'fallback_denied')
      expect(decision).to have_attributes(availability: 'allowed', can_add: true)
    end

    it 'deny outranks the limit (F5)' do
      decision = kind_of(input(node: fallback_node, viewer: { fallback_policy: :deny }, counts: counts(3, 0, 0), local_max: 3), :unicode)

      expect(decision).to have_attributes(availability: 'disabled', reason: 'fallback_denied')
    end
  end

  describe 'limits (docs section 4 truth tables)' do
    def native_node(max)
      node({ 'emoji_reaction_type' => 'custom', 'emoji_reaction_max' => max }.compact)
    end

    # [description, target_max, total, native, unknown, local_max, expected target_current, expected remaining, known, availability, reason]
    [
      ['native cap 5, none used',                      5, 0, 0, 0, 3, 0,   3, true,  'allowed',       nil],
      ['native cap 5, local exhausted',                5, 3, 3, 0, 3, 3,   0, true,  'limit_reached', 'limit_reached_local'],
      ['native cap 1, used',                           1, 1, 1, 0, 3, 1,   0, true,  'limit_reached', 'limit_reached_target'],
      ['native cap 1, none used',                      1, 0, 0, 0, 3, 0,   1, true,  'allowed',       nil],
      ['native cap unknown, 2 used',                   nil, 2, 2, 0, 3, nil, 1, false, 'allowed',      nil],
      ['native cap unknown, local exhausted',          nil, 3, 3, 0, 3, nil, 0, false, 'limit_reached', 'limit_reached_local'],
      ['native cap 1, the one row is like_fallback',   1, 1, 0, 0, 3, 0,   1, true,  'allowed',       nil],
      ['native cap 1, one legacy row (unknown)',       1, 1, 0, 1, 3, nil, 2, false, 'allowed',       nil],
      ['local_max 1 and one row of any mechanism',     5, 1, 0, 1, 1, nil, 0, false, 'limit_reached', 'limit_reached_local'],
    ].each do |description, target_max, total, native, unknown, local_max, target_current, remaining, known, availability, reason|
      it description do
        decision = kind_of(input(node: native_node(target_max), counts: counts(total, native, unknown), local_max: local_max), :unicode)

        expect(decision.limit).to include(target_current: target_current, remaining: remaining, target_limit_known: known)
        expect(decision).to have_attributes(availability: availability, reason: reason)
      end
    end

    it 'counts every row as unknown for legacy counts and never enforces a target limit from them' do
      decision = kind_of(input(node: native_node(1), counts: EmojiReactionCapability::Counts.legacy(1), local_max: 3), :unicode)

      expect(decision.limit).to include(target_current: nil, target_remaining: nil, remaining: 2, target_limit_known: false)
      expect(decision.availability).to eq 'allowed'
    end

    it 'never asserts a limit when counts or the local cap were not read' do
      decision = kind_of(input(node: native_node(1)), :unicode)

      expect(decision.limit).to include(remaining: nil, target_limit_known: false)
      expect(decision.availability).to eq 'allowed'
    end

    it 'limits a fallback kind only by the local cap and never uses the native target limit' do
      fallback = node('emoji_reaction_type' => 'unicode', 'emoji_reaction_max' => 1, 'favourite' => true)

      custom = kind_of(input(node: fallback, counts: counts(1, 1, 0), local_max: 3), :custom)
      unicode = kind_of(input(node: fallback, counts: counts(1, 1, 0), local_max: 3), :unicode)

      expect(custom.limit).to include(target_max: nil, target_current: nil, remaining: 2, target_limit_known: false)
      expect(unicode).to have_attributes(availability: 'limit_reached', reason: 'limit_reached_target')
    end

    it 'M5/M6: a fallback row does not use the native limit, and a native row does not limit the fallback kind' do
      fallback = node('emoji_reaction_type' => 'unicode', 'emoji_reaction_max' => 1, 'favourite' => true)

      after_fallback_row = described_class.call(input(node: fallback, counts: counts(1, 0, 0), local_max: 3))
      after_native_row = described_class.call(input(node: fallback, counts: counts(1, 1, 0), local_max: 3))

      expect(after_fallback_row.kinds[:unicode].limit).to include(target_current: 0, remaining: 1)
      expect(after_native_row.kinds[:unicode]).to have_attributes(availability: 'limit_reached', reason: 'limit_reached_target')
      expect(after_native_row.kinds[:custom]).to have_attributes(availability: 'allowed', can_add: true)
    end

    it 'does not apply a target limit to a local author' do
      decision = kind_of(input(node: native_node(1), status: { author_local: true }, counts: counts(2, 2, 0), local_max: 3), :unicode)

      expect(decision.limit).to include(target_max: nil, remaining: 1)
    end

    it 'omits the per-kind limit for an unsupported kind' do
      decision = kind_of(input(node: node({ 'emoji_reaction_type' => 'none', 'favourite' => 'none' }), counts: counts(0, 0, 0), local_max: 3), :unicode)

      expect(decision).to have_attributes(availability: 'unsupported', limit: nil)
    end
  end

  describe 'availability to booleans mapping and aggregate' do
    it 'ties availability to can_add and requires_confirmation for every kind object' do
      shapes = [
        [node('emoji_reaction_type' => 'custom'), {}, nil],
        [node('emoji_reaction_type' => 'none', 'favourite' => true), { fallback_policy: :ask }, nil],
        [node({}), {}, nil],
        [node('emoji_reaction_type' => 'none', 'favourite' => true), { fallback_policy: :deny }, nil],
        [node('emoji_reaction_type' => 'none', 'favourite' => 'none'), {}, nil],
        [node('emoji_reaction_type' => 'custom'), {}, counts(3, 3, 0)],
        [node('emoji_reaction_type' => 'custom'), { disable_reactions: true }, nil],
      ]

      expected = {
        'allowed' => [true, false], 'unknown' => [true, false], 'confirm' => [true, true],
        'limit_reached' => [false, false], 'disabled' => [false, false], 'unsupported' => [false, false]
      }

      shapes.each do |snapshot, viewer, count|
        decision = described_class.call(input(node: snapshot, viewer: viewer, counts: count, local_max: count ? 3 : nil))

        [decision, *decision.kinds.values].each do |item|
          expect([item.can_add, item.requires_confirmation]).to eq expected.fetch(item.availability)
          expect(item.reason).to be_nil if item.availability == 'allowed'
        end
      end
    end

    it 'aggregates to the best kind: confirm only when no kind is addable without confirmation' do
      ask = described_class.call(input(node: node({ 'emoji_reaction_type' => 'none', 'favourite' => true }), viewer: { fallback_policy: :ask }))
      mixed = described_class.call(input(node: node({ 'emoji_reaction_type' => 'unicode', 'favourite' => true }), viewer: { fallback_policy: :ask }))

      expect(ask).to have_attributes(availability: 'confirm', can_add: true, requires_confirmation: true)
      expect(mixed).to have_attributes(availability: 'allowed', can_add: true, requires_confirmation: false)
    end

    it 'derives can_remove from the viewer total only' do
      expect(described_class.call(input(node: node, counts: counts(1, 0, 1))).can_remove).to be true
      expect(described_class.call(input(node: node, counts: counts(0, 0, 0))).can_remove).to be false
      expect(described_class.call(input(node: node, viewer: { disable_reactions: true }, counts: counts(1, 0, 1))).can_remove).to be true
    end
  end
end
