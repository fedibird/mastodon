# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmojiReactionCapability::ShadowConfig do
  def with_env(**values, &block)
    ClimateControl.modify(values, &block)
  end

  it 'is off by default and in any value other than true' do
    with_env(EMOJI_REACTION_RESOLVER_SHADOW: nil) { expect(described_class.enabled?).to be false }

    %w(false 1 TRUE yes).each do |value|
      with_env(EMOJI_REACTION_RESOLVER_SHADOW: value) { expect(described_class.enabled?).to be false }
    end

    with_env(EMOJI_REACTION_RESOLVER_SHADOW: 'true') { expect(described_class.enabled?).to be true }
  end

  describe '.sample_rate' do
    it 'defaults to a low rate and clamps and fails closed' do
      with_env(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: nil) { expect(described_class.sample_rate).to eq 0.01 }
      with_env(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '') { expect(described_class.sample_rate).to eq 0.01 }
      with_env(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '0.25') { expect(described_class.sample_rate).to eq 0.25 }
      with_env(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '7') { expect(described_class.sample_rate).to eq 1.0 }
      with_env(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '-1') { expect(described_class.sample_rate).to eq 0.0 }
      with_env(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: 'abc') { expect(described_class.sample_rate).to eq 0.0 }
    end
  end

  describe '.sample?' do
    let(:random) { instance_double(Random) }

    it 'is false when the flag is off, without drawing' do
      expect(random).not_to receive(:rand)
      with_env(EMOJI_REACTION_RESOLVER_SHADOW: nil, EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '1') { expect(described_class.sample?(random: random)).to be false }
    end

    it 'is false at rate 0 without drawing and true at rate 1 without drawing' do
      expect(random).not_to receive(:rand)
      with_env(EMOJI_REACTION_RESOLVER_SHADOW: 'true', EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '0') { expect(described_class.sample?(random: random)).to be false }
      with_env(EMOJI_REACTION_RESOLVER_SHADOW: 'true', EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '1') { expect(described_class.sample?(random: random)).to be true }
    end

    it 'samples below the rate' do
      allow(random).to receive(:rand).and_return(0.05, 0.5)
      with_env(EMOJI_REACTION_RESOLVER_SHADOW: 'true', EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '0.1') do
        expect(described_class.sample?(random: random)).to be true
        expect(described_class.sample?(random: random)).to be false
      end
    end
  end
end

RSpec.describe EmojiReactionCapability::ShadowComparator do
  let(:now) { Time.utc(2026, 10, 25) }
  let(:custom_node) { EmojiReactionCapability::NodeSnapshot.from_attributes(info: { 'emoji_reaction_type' => 'custom' }, info_override: nil, nodeinfo_missing: false, status: 'up', last_fetched_at: now, now: now) }

  def plan_for(node, kind)
    EmojiReactionCapability::DeliveryPlan.for_status(EmojiReactionCapability::StatusContext.new, node, kind)
  end

  it 'reports match and diff with bounded values' do
    match = described_class.compare(op: :create, kind: :unicode, legacy_type: 'EmojiReact', plan: plan_for(custom_node, :unicode), node: custom_node)
    diff = described_class.compare(op: :undo, kind: :unicode, legacy_type: 'Like', plan: plan_for(custom_node, :unicode), node: custom_node)

    expect(match).to include(result: 'match', legacy: 'EmojiReact', proposed: 'EmojiReact', node: 'known', family: 'unknown')
    expect(diff).to include(result: 'diff', legacy: 'Like', proposed: 'EmojiReact', basis: 'native')
  end

  it 'maps nil to none on both sides' do
    plan = EmojiReactionCapability::DeliveryPlan.for_status(EmojiReactionCapability::StatusContext.new(author_silenced: true), nil, :unicode)
    result = described_class.compare(op: :create, kind: :unicode, legacy_type: nil, plan: plan)

    expect(result).to include(result: 'match', legacy: 'none', proposed: 'none', node: 'not_read', family: 'none', basis: 'author_silenced')
  end

  it 'labels representative diffs' do
    expect(described_class.reason(op: 'undo', legacy: 'Like', proposed: 'EmojiReact', basis: 'native')).to eq 'undo_asymmetry_native_sent_as_like'
    expect(described_class.reason(op: 'undo', legacy: 'Like', proposed: 'none', basis: 'author_silenced')).to eq 'undo_not_skipped_for_silenced'
    expect(described_class.reason(op: 'create', legacy: 'EmojiReact', proposed: 'Like', basis: 'unicode_only_custom')).to eq 'unicode_only_node_custom_emoji'
    expect(described_class.reason(op: 'create', legacy: 'Like', proposed: 'none', basis: 'unsupported_node')).to eq 'proposed_refusal'
    expect(described_class.reason(op: 'fanout_create', legacy: 'none', proposed: 'Like', basis: 'unknown_type')).to eq 'unknown_node_type'
    expect(described_class.reason(op: 'create', legacy: 'Like', proposed: 'Like', basis: 'native')).to eq 'match'
  end
end

RSpec.describe EmojiReactionCapability::ShadowRecorder do
  let(:now) { Time.utc(2026, 10, 25, 9, 30) }

  it 'builds fields from closed vocabularies only' do
    obs = { op: 'create', kind: 'unicode', family: 'evil.example.com', node: 'known', legacy: 'Like', proposed: 'EmojiReact', basis: ':emoji:', result: 'diff' }

    field = described_class.comparison_field(obs)

    expect(field).to eq 'cmp|op=create|kind=unicode|family=other|node=known|legacy=Like|proposed=EmojiReact|basis=other|result=diff'
    expect(field).not_to include('evil')
  end

  it 'writes hourly buckets with a TTL, aggregates, and is bounded to the vocabulary' do
    fields = { 'cmp|op=create' => 2 }
    described_class.increment(fields, now: now)
    described_class.increment(fields, now: now)

    key = described_class.key_for(now)
    expect(key).to eq 'emoji_reaction_shadow:v1:2026102509'
    expect(redis.hget(key, 'cmp|op=create').to_i).to eq 4
    expect(redis.ttl(key)).to be_between(1, described_class::RETENTION.to_i)
  end

  it 'does nothing for no fields' do
    expect(RedisConfiguration).not_to receive(:with)
    described_class.increment({}, now: now)
  end
end

RSpec.describe EmojiReactionCapability::ShadowReport do
  it 'summarizes counters and renders them' do
    fields = {
      'cmp|op=create|kind=unicode|family=mastodon|node=known|legacy=EmojiReact|proposed=EmojiReact|basis=native|result=match' => 8,
      'cmp|op=create|kind=unicode|family=unknown|node=unknown_type|legacy=EmojiReact|proposed=Like|basis=unknown_type|result=diff' => 2,
      'cmp|op=undo|kind=unicode|family=mastodon|node=known|legacy=Like|proposed=EmojiReact|basis=native|result=diff' => 5,
      'snap|src=author|node=known|family=mastodon|reach=up|stale=1|override=0|stale_ignored=0' => 8,
      'snap|src=author|node=nodeinfo_missing|family=unknown|reach=up|stale=0|override=1|stale_ignored=1' => 2,
      'err|op=create' => 1,
    }

    summary = described_class.summarize(fields)

    expect(summary[:ops]['create']).to eq(total: 10, match: 8, diff: 2)
    expect(summary[:ops]['undo']).to eq(total: 5, match: 0, diff: 5)
    expect(summary[:flags]).to eq(stale: 8, override: 2, stale_ignored: 2, total: 10)
    expect(summary[:errors]).to eq('create' => 1)

    text = described_class.render(summary)
    expect(text).to include('match_rate=80.0%')
    expect(text).to include('undo_asymmetry_native_sent_as_like')
    expect(text).to include('unknown_node_type')
  end

  it 'collects across hourly buckets' do
    now = Time.utc(2026, 10, 25, 9, 30)
    EmojiReactionCapability::ShadowRecorder.increment({ 'err|op=undo' => 1 }, now: now)
    EmojiReactionCapability::ShadowRecorder.increment({ 'err|op=undo' => 2 }, now: now - 1.hour)
    EmojiReactionCapability::ShadowRecorder.increment({ 'err|op=undo' => 4 }, now: now - 5.hours)

    expect(described_class.collect(hours: 2, now: now)).to eq('err|op=undo' => 3)
    expect(described_class.collect(hours: 6, now: now)).to eq('err|op=undo' => 7)
  end
end
