# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmojiReactionCapability::NodeSnapshot do
  let(:now) { Time.utc(2026, 10, 25, 12, 0, 0) }

  def snapshot(info: {}, info_override: nil, nodeinfo_missing: false, status: 'up', last_fetched_at: now - 1.day)
    described_class.from_attributes(
      info: info,
      info_override: info_override,
      nodeinfo_missing: nodeinfo_missing,
      status: status,
      last_fetched_at: last_fetched_at,
      now: now
    )
  end

  describe 'emoji_reaction_type' do
    {
      'custom' => 'custom',
      'unicode' => 'unicode',
      'none' => 'none',
      nil => 'unknown',
      'other' => 'unknown',
      true => 'unknown',
      0 => 'unknown',
    }.each do |raw, expected|
      it "maps #{raw.inspect} to #{expected}" do
        expect(snapshot(info: { 'emoji_reaction_type' => raw }).emoji_reaction_type).to eq expected
      end
    end

    it 'treats an absent key as unknown, not as the legacy custom default' do
      expect(snapshot(info: {}).emoji_reaction_type).to eq 'unknown'
      expect(Node.new(info: {}).features(:emoji_reaction_type)).to eq 'custom'
    end

    it 'treats a non-Hash info as empty' do
      expect(snapshot(info: ['custom']).emoji_reaction_type).to eq 'unknown'
      expect(snapshot(info: nil).emoji_reaction_type).to eq 'unknown'
    end
  end

  describe 'like_delivery (favourite)' do
    {
      true => :accepts,
      'public' => :accepts,
      'true' => :accepts,
      'none' => :rejects,
      false => :unknown,
      nil => :unknown,
      'other' => :unknown,
      1 => :unknown,
    }.each do |raw, expected|
      it "maps #{raw.inspect} to #{expected}" do
        expect(snapshot(info: { 'favourite' => raw }).like_delivery).to eq expected
      end
    end

    it 'maps an absent key to unknown' do
      expect(snapshot(info: {}).like_delivery).to eq :unknown
    end
  end

  describe 'max_per_account (emoji_reaction_max)' do
    it 'keeps a positive Integer' do
      expect(snapshot(info: { 'emoji_reaction_type' => 'custom', 'emoji_reaction_max' => 5 }).max_per_account).to eq 5
    end

    it 'keeps 0 only with the none type' do
      expect(snapshot(info: { 'emoji_reaction_type' => 'none', 'emoji_reaction_max' => 0 }).max_per_account).to eq 0
      expect(snapshot(info: { 'emoji_reaction_type' => 'custom', 'emoji_reaction_max' => 0 }).max_per_account).to be_nil
    end

    it 'maps negative, non-Integer and absent values to nil' do
      [-1, 1.5, '3', nil, true].each do |raw|
        expect(snapshot(info: { 'emoji_reaction_type' => 'custom', 'emoji_reaction_max' => raw }).max_per_account).to be_nil
      end
      expect(snapshot(info: { 'emoji_reaction_type' => 'custom' }).max_per_account).to be_nil
    end

    it 'does not copy the local site cap' do
      expect(snapshot(info: { 'emoji_reaction_type' => 'custom' }).max_per_account).to be_nil
    end
  end

  describe 'reachability' do
    { 'up' => :up, 'gone' => :gone, 'error' => :unknown, 'busy' => :unknown, 'reject' => :unknown, 'not_found' => :unknown, 'no_address' => :unknown }.each do |raw, expected|
      it "maps #{raw} to #{expected}" do
        expect(snapshot(status: raw).reachability).to eq expected
      end
    end
  end

  describe 'precedence: admin override, missing NodeInfo, info' do
    let(:stale_info) { { 'emoji_reaction_type' => 'custom', 'favourite' => true, 'emoji_reaction_max' => 3, 'software_name' => 'mastodon' } }

    it 'ignores stale info when NodeInfo is missing and reports that it did' do
      node = snapshot(info: stale_info, nodeinfo_missing: true)

      expect(node.emoji_reaction_type).to eq 'unknown'
      expect(node.type_source).to eq :missing_nodeinfo
      expect(node.like_delivery).to eq :unknown
      expect(node.max_per_account).to be_nil
      expect(node.software).to be_nil
      expect(node.stale_info_ignored).to be true
      expect(node.state).to eq 'nodeinfo_missing'
    end

    it 'does not report stale_info_ignored when info holds no usable type' do
      expect(snapshot(info: {}, nodeinfo_missing: true).stale_info_ignored).to be false
    end

    it 'lets an admin override win when NodeInfo is missing' do
      node = snapshot(info: stale_info, info_override: { 'emoji_reaction_type' => 'unicode', 'favourite' => 'none' }, nodeinfo_missing: true)

      expect(node.emoji_reaction_type).to eq 'unicode'
      expect(node.type_source).to eq :override
      expect(node.like_delivery).to eq :rejects
      expect(node.admin_override).to be true
      expect(node.stale_info_ignored).to be false
      expect(node.state).to eq 'known'
    end

    it 'lets an admin override win over a current NodeInfo value' do
      node = snapshot(info: { 'emoji_reaction_type' => 'custom' }, info_override: { 'emoji_reaction_type' => 'none' })

      expect(node.emoji_reaction_type).to eq 'none'
      expect(node.type_source).to eq :override
    end

    it 'decides each field independently' do
      node = snapshot(info: stale_info, info_override: { 'emoji_reaction_type' => 'custom' }, nodeinfo_missing: true)

      expect(node.emoji_reaction_type).to eq 'custom'
      expect(node.like_delivery).to eq :unknown
    end

    it 'treats an override key with a nil value as deciding (unknown)' do
      node = snapshot(info: stale_info, info_override: { 'emoji_reaction_type' => nil })

      expect(node.emoji_reaction_type).to eq 'unknown'
      expect(node.type_source).to eq :override
    end

    it 'uses info when NodeInfo is present' do
      node = snapshot(info: stale_info)

      expect(node.emoji_reaction_type).to eq 'custom'
      expect(node.type_source).to eq :info
      expect(node.max_per_account).to eq 3
      expect(node.admin_override).to be false
    end
  end

  describe 'software shapes' do
    it 'maps kmyblue to a like_fallback mechanism override' do
      node = snapshot(info: { 'software_name' => 'kmyblue', 'upstream_name' => 'mastodon', 'emoji_reaction_type' => 'custom', 'favourite' => true })

      expect(node.mechanism_override).to eq :like_fallback
      expect(node.family).to eq 'kmyblue'
    end

    it 'lets an admin override of software_name decide the kmyblue rule' do
      node = snapshot(info: { 'software_name' => 'kmyblue' }, info_override: { 'software_name' => 'mastodon' })

      expect(node.mechanism_override).to be_nil
    end

    it 'maps the birdsitelive override exactly as UpdateNodeService produces it' do
      info = { 'software_name' => 'bird.makeup', 'upstream_name' => 'birdsitelive', 'emoji_reaction_type' => 'none', 'emoji_reaction_max' => 0, 'favourite' => 'none', 'reply' => 'none', 'reblog' => 'none', 'reference' => 'none' }
      node = snapshot(info: info)

      expect(node.emoji_reaction_type).to eq 'none'
      expect(node.like_delivery).to eq :rejects
      expect(node.max_per_account).to eq 0
      expect(node.family).to eq 'birdsitelive'
    end

    it 'does not treat the misskey family favourite false as a rejection of Like' do
      info = { 'software_name' => 'sharkey', 'upstream_name' => 'misskey', 'emoji_reaction_type' => 'custom', 'favourite' => false }
      node = snapshot(info: info)

      expect(node.like_delivery).to eq :unknown
      expect(node.family).to eq 'misskey'
    end

    it 'reports bounded families only' do
      expect(snapshot(info: { 'software_name' => 'mastodon' }).family).to eq 'mastodon'
      expect(snapshot(info: { 'software_name' => 'hometown', 'upstream_name' => 'mastodon' }).family).to eq 'mastodon'
      expect(snapshot(info: { 'software_name' => 'some-new-thing' }).family).to eq 'other'
      expect(snapshot(info: {}).family).to eq 'unknown'
      expect(described_class.absent.family).to eq 'unknown'
    end
  end

  describe 'stale' do
    it 'is true when last_fetched_at is nil or older than the configured age' do
      expect(snapshot(last_fetched_at: nil).stale).to be true
      expect(snapshot(last_fetched_at: now - 31.days).stale).to be true
      expect(snapshot(last_fetched_at: now - 29.days).stale).to be false
    end

    it 'does not change the normalized value' do
      expect(snapshot(info: { 'emoji_reaction_type' => 'custom' }, last_fetched_at: nil).emoji_reaction_type).to eq 'custom'
    end
  end

  describe '.absent' do
    it 'is unknown everywhere and not row_present' do
      node = described_class.absent

      expect(node).to have_attributes(row_present: false, emoji_reaction_type: 'unknown', like_delivery: :unknown, max_per_account: nil, reachability: :unknown, type_source: :no_row)
      expect(node.state).to eq 'no_row'
    end
  end
end

RSpec.describe EmojiReactionCapability::NodeSnapshotLoader do
  let(:now) { Time.utc(2026, 10, 25, 12, 0, 0) }

  def statements
    sqls = []
    callback = ->(*, payload) { sqls << payload[:sql].to_s unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    sqls
  end

  before do
    Node.create!(domain: 'null-nodeinfo.example', info: { 'emoji_reaction_type' => 'custom' }, nodeinfo: nil)
    Node.create!(domain: 'missing.example', info: { 'emoji_reaction_type' => 'custom' }, nodeinfo: { 'error' => 'missing' })
    Node.create!(domain: 'present.example', info: { 'emoji_reaction_type' => 'unicode' }, nodeinfo: { 'software' => { 'name' => 'x' }, 'padding' => 'x' * 1000 })
    Node.create!(domain: 'override.example', info: { 'emoji_reaction_type' => 'custom' }, info_override: { 'emoji_reaction_type' => 'none' }, nodeinfo: { 'error' => 'missing' })
    Node.create!(domain: 'gone.example', info: { 'emoji_reaction_type' => 'custom' }, nodeinfo: { 'a' => 1 }, status: :gone)
  end

  it 'evaluates the NodeInfo-missing condition like Node#missing? without selecting the nodeinfo column' do
    domains = %w(null-nodeinfo.example missing.example present.example override.example gone.example none.example)
    result = nil
    sqls = statements { result = described_class.load_many(domains, now: now) }

    expect(sqls.size).to eq 1
    expect(sqls.first).not_to match(/"nodes"\."nodeinfo"(?! IS| ->>)/)
    expect(sqls.first).not_to include('instance_data')

    domains.first(5).each do |domain|
      node = Node.find_by(domain: domain)
      expect(result[domain].nodeinfo_missing).to eq(node.missing?), domain
    end

    expect(result['null-nodeinfo.example'].emoji_reaction_type).to eq 'unknown'
    expect(result['missing.example'].stale_info_ignored).to be true
    expect(result['present.example'].emoji_reaction_type).to eq 'unicode'
    expect(result['override.example'].emoji_reaction_type).to eq 'none'
    expect(result['gone.example'].reachability).to eq :gone
    expect(result['none.example']).to eq EmojiReactionCapability::NodeSnapshot.absent
  end

  it 'issues no query for no domains and one query regardless of the number of domains' do
    expect(statements { described_class.load_many([], now: now) }).to be_empty
    expect(statements { described_class.load_many(%w(missing.example present.example), now: now) }.size).to eq 1
    expect(statements { described_class.load_many(Array.new(40) { |i| "n#{i}.example" }, now: now) }.size).to eq 1
  end
end
