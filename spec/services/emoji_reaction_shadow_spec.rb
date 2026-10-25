# frozen_string_literal: true

require 'rails_helper'

# P1a shadow mode: the legacy services stay the only actor. These specs pin
# (a) what the legacy code sends today (flag OFF parity), (b) that turning the
# flag ON changes neither payloads, recipients nor jobs, and (c) what the
# shadow records when it compares legacy with the proposed plan.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Emoji reaction resolver shadow mode' do
  let(:domain) { 'remote.example' }
  let(:reactor) { Fabricate(:account, username: 'reactor') }
  let(:author) { Fabricate(:account, username: 'zorblax', domain: domain, protocol: :activitypub, inbox_url: "https://#{domain}/inbox", uri: "https://#{domain}/users/author") }
  let(:status) { Fabricate(:status, account: author, uri: "https://#{domain}/users/author/statuses/1") }
  let(:custom_emoji) { Fabricate(:custom_emoji, shortcode: 'coolcat') }

  let(:on_env) { { EMOJI_REACTION_RESOLVER_SHADOW: 'true', EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '1' } }
  let(:off_env) { { EMOJI_REACTION_RESOLVER_SHADOW: nil, EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: nil } }

  def shadow_on(&block)
    ClimateControl.modify(on_env, &block)
  end

  def shadow_off(&block)
    ClimateControl.modify(off_env, &block)
  end

  def emoji_arg(kind)
    kind == :unicode ? '👍' : custom_emoji.shortcode
  end

  def make_node(info: {}, nodeinfo: { 'software' => { 'name' => 'x' } }, info_override: nil, node_status: :up, fetched: Time.now.utc)
    Node.create!(domain: domain, info: info, nodeinfo: nodeinfo, info_override: info_override, status: node_status, last_fetched_at: fetched)
  end

  def deliveries
    ActivityPub::DeliveryWorker.jobs.map do |job|
      json, account_id, inbox_url = job['args']
      payload = Oj.load(json)
      type = payload['type'] == 'Undo' ? payload['object']['type'] : payload['type']
      { type: type, account_id: account_id, inbox_url: inbox_url, json: json }
    end
  end

  # Row ids and the LD signature (created timestamp) differ between runs.
  def normalized(json)
    Oj.load(json).except('signature').to_json.gsub(%r{emoji_reactions/\d+}, 'emoji_reactions/N')
  end

  def create_jobs(kind, status: self.status)
    ActivityPub::DeliveryWorker.jobs.clear
    EmojiReactionService.new.call(reactor, status, emoji_arg(kind))
    deliveries
  end

  def undo_jobs(kind, status: self.status)
    ActivityPub::DeliveryWorker.jobs.clear
    UnEmojiReactionService.new.call(reactor, status, emoji_arg(kind), shortcode_only: true)
    deliveries
  end

  def counters
    EmojiReactionCapability::ShadowReport.collect(hours: 1)
  end

  def recorded
    counters.select { |field, _| field.start_with?('cmp|') }.transform_keys do |field|
      field.split('|').drop(1).to_h { |pair| pair.split('=', 2) }.symbolize_keys
    end
  end

  def recorded_total(**filters)
    recorded.select { |key, _| filters.all? { |k, v| key[k] == v } }.values.sum
  end

  def capture_sql(&block)
    statements = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      statements << sql unless payload[:name] == 'SCHEMA' || sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    statements
  end

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  before { ActivityPub::DeliveryWorker.jobs.clear }

  # The legacy value is today's actual behavior, asserted against the real
  # services with the flag OFF. The proposed value and basis are the shadow's
  # plan. Format: [legacy type, proposed type, basis].
  #
  # node: attributes for make_node, or nil for no Node row.
  # Undo is [:raises] where legacy UnEmojiReactionService raises today
  # (unicode emoji, remote ActivityPub author, no Node row).
  shapes = {
    'no Node row' => {
      node: nil,
      unicode: { create: %w(Like Like unknown_no_row), undo: [:raises] },
      custom: { create: %w(Like Like unknown_no_row), undo: %w(Like Like unknown_no_row) },
    },
    'empty info (type key absent)' => {
      node: { info: {} },
      unicode: { create: %w(EmojiReact Like unknown_type), undo: %w(Like Like unknown_type) },
      custom: { create: %w(EmojiReact Like unknown_type), undo: %w(Like Like unknown_type) },
    },
    'custom type' => {
      node: { info: { 'emoji_reaction_type' => 'custom', 'favourite' => true } },
      unicode: { create: %w(EmojiReact EmojiReact native), undo: %w(Like EmojiReact native) },
      custom: { create: %w(EmojiReact EmojiReact native), undo: %w(Like EmojiReact native) },
    },
    'unicode-only type' => {
      node: { info: { 'emoji_reaction_type' => 'unicode', 'favourite' => true } },
      unicode: { create: %w(EmojiReact EmojiReact native), undo: %w(EmojiReact EmojiReact native) },
      custom: { create: %w(EmojiReact Like unicode_only_custom), undo: %w(Like Like unicode_only_custom) },
    },
    'none type, Like accepted' => {
      node: { info: { 'emoji_reaction_type' => 'none', 'favourite' => true } },
      unicode: { create: %w(Like Like like_fallback), undo: %w(Like Like like_fallback) },
      custom: { create: %w(Like Like like_fallback), undo: %w(Like Like like_fallback) },
    },
    'birdsitelive (none type, favourite none)' => {
      node: { info: { 'software_name' => 'bird.makeup', 'upstream_name' => 'birdsitelive', 'emoji_reaction_type' => 'none', 'emoji_reaction_max' => 0, 'favourite' => 'none' } },
      unicode: { create: %w(Like none unsupported_node), undo: %w(Like none unsupported_node) },
      custom: { create: %w(Like none unsupported_node), undo: %w(Like none unsupported_node) },
    },
    'misskey family (custom type, favourite false)' => {
      node: { info: { 'software_name' => 'sharkey', 'upstream_name' => 'misskey', 'emoji_reaction_type' => 'custom', 'favourite' => false } },
      unicode: { create: %w(EmojiReact EmojiReact native), undo: %w(Like EmojiReact native) },
      custom: { create: %w(EmojiReact EmojiReact native), undo: %w(Like EmojiReact native) },
    },
    'kmyblue' => {
      node: { info: { 'software_name' => 'kmyblue', 'upstream_name' => 'mastodon', 'emoji_reaction_type' => 'custom', 'favourite' => true } },
      unicode: { create: %w(Like Like mechanism_override_like), undo: %w(Like Like mechanism_override_like) },
      custom: { create: %w(Like Like mechanism_override_like), undo: %w(Like Like mechanism_override_like) },
    },
    'NodeInfo missing with stale custom info' => {
      node: { info: { 'emoji_reaction_type' => 'custom', 'favourite' => true }, nodeinfo: { 'error' => 'missing' } },
      unicode: { create: %w(EmojiReact Like unknown_nodeinfo_missing), undo: %w(Like Like unknown_nodeinfo_missing) },
      custom: { create: %w(EmojiReact Like unknown_nodeinfo_missing), undo: %w(Like Like unknown_nodeinfo_missing) },
    },
    'NodeInfo missing with admin override custom' => {
      node: { info: { 'emoji_reaction_type' => 'custom' }, nodeinfo: nil, info_override: { 'emoji_reaction_type' => 'custom' } },
      unicode: { create: %w(EmojiReact EmojiReact native), undo: %w(Like EmojiReact native) },
      custom: { create: %w(EmojiReact EmojiReact native), undo: %w(Like EmojiReact native) },
    },
    'gone Node with custom type' => {
      node: { info: { 'emoji_reaction_type' => 'custom' }, node_status: :gone },
      unicode: { create: %w(EmojiReact none unsupported_gone), undo: %w(Like none unsupported_gone) },
      custom: { create: %w(EmojiReact none unsupported_gone), undo: %w(Like none unsupported_gone) },
    },
  }.freeze

  shapes.each do |name, shape|
    %i(unicode custom).each do |kind|
      context "with #{name}, #{kind} emoji" do
        let(:legacy_create) { shape.dig(kind, :create) }
        let(:legacy_undo) { shape.dig(kind, :undo) }

        before { make_node(**shape[:node]) if shape[:node] }

        it 'sends today\'s activity type with the flag OFF (legacy parity) and writes no counter' do
          shadow_off do
            expect(create_jobs(kind).pluck(:type)).to eq [legacy_create[0]]

            if legacy_undo == [:raises]
              expect { undo_jobs(kind) }.to raise_error(NoMethodError)
            else
              expect(undo_jobs(kind).pluck(:type)).to eq [legacy_undo[0]]
            end
          end

          expect(counters).to be_empty
        end

        it 'sends the same jobs with the flag ON and records legacy versus proposed' do
          baseline = shadow_off { create_jobs(kind) }
          EmojiReaction.where(account: reactor).destroy_all

          shadow_on do
            on_create = create_jobs(kind)

            expect(on_create.pluck(:type, :inbox_url, :account_id)).to eq baseline.pluck(:type, :inbox_url, :account_id)
            expect(on_create.map { |d| normalized(d[:json]) }).to eq(baseline.map { |d| normalized(d[:json]) })

            if legacy_undo == [:raises]
              expect { undo_jobs(kind) }.to raise_error(NoMethodError)
            else
              expect(undo_jobs(kind).pluck(:type)).to eq [legacy_undo[0]]
            end
          end

          legacy, proposed, basis = legacy_create
          expect(recorded_total(op: 'create', kind: kind.to_s, legacy: legacy, proposed: proposed, basis: basis, result: legacy == proposed ? 'match' : 'diff')).to eq 1
          expect(recorded_total(op: 'create')).to eq 1

          if legacy_undo == [:raises]
            expect(recorded_total(op: 'undo')).to eq 0
          else
            legacy, proposed, basis = legacy_undo
            expect(recorded_total(op: 'undo', kind: kind.to_s, legacy: legacy, proposed: proposed, basis: basis, result: legacy == proposed ? 'match' : 'diff')).to eq 1
            expect(recorded_total(op: 'undo')).to eq 1
          end
        end
      end
    end
  end

  describe 'author conditions' do
    before { make_node(info: { 'emoji_reaction_type' => 'custom', 'favourite' => true }) }

    it 'compares a silenced author: create sends nothing, legacy Undo is not skipped' do
      author.update!(silenced_at: Time.now.utc)

      shadow_on do
        expect(create_jobs(:unicode)).to be_empty
        expect(undo_jobs(:unicode).pluck(:type)).to eq ['Like']
      end

      expect(recorded_total(op: 'create', legacy: 'none', proposed: 'none', basis: 'author_silenced', result: 'match')).to eq 1
      expect(recorded_total(op: 'undo', legacy: 'Like', proposed: 'none', basis: 'author_silenced', result: 'diff')).to eq 1
    end

    it 'compares a non-ActivityPub remote author as local-only on both sides' do
      author.update!(protocol: :ostatus)

      shadow_on do
        expect(create_jobs(:custom)).to be_empty
        expect(undo_jobs(:custom)).to be_empty
      end

      expect(recorded_total(basis: 'not_activitypub', result: 'match')).to eq 2
    end

    it 'does not read a Node when the proposed plan does not need one' do
      author.update!(silenced_at: Time.now.utc)

      sqls = capture_sql { shadow_on { create_jobs(:unicode) } }

      expect(sqls.grep(/nodeinfo_missing/)).to be_empty
    end

    it 'uses the canonical status author for a reaction made through a boost wrapper' do
      booster = Fabricate(:account, username: 'booster', domain: 'booster.example', protocol: :activitypub, inbox_url: 'https://booster.example/inbox', uri: 'https://booster.example/users/booster')
      Node.create!(domain: 'booster.example', info: { 'emoji_reaction_type' => 'none', 'favourite' => 'none' }, nodeinfo: { 'a' => 1 }, last_fetched_at: Time.now.utc)
      wrapper = Fabricate(:status, account: booster, reblog: status, uri: 'https://booster.example/users/booster/statuses/9')

      shadow_on do
        jobs = create_jobs(:unicode, status: wrapper)

        expect(jobs.pluck(:inbox_url)).to eq ["https://#{domain}/inbox"]
        expect(jobs.pluck(:type)).to eq ['EmojiReact']
      end

      expect(recorded_total(op: 'create', legacy: 'EmojiReact', proposed: 'EmojiReact', basis: 'native', result: 'match')).to eq 1
      expect(recorded_total(basis: 'unsupported_node')).to eq 0
    end

    it 'does not observe a local author in create (the fan-out hook does)' do
      local_status = Fabricate(:status, account: Fabricate(:account, username: 'localauthor'))

      shadow_on { EmojiReactionService.new.call(reactor, local_status, '👍') }

      expect(recorded).to be_empty
    end
  end

  describe 'sampling and failure containment' do
    before { make_node(info: { 'emoji_reaction_type' => 'custom' }) }

    it 'performs no shadow query or Redis write when the flag is off' do
      expect(EmojiReactionCapability::NodeSnapshotLoader).not_to receive(:load)
      expect(EmojiReactionCapability::ShadowRecorder).not_to receive(:increment)

      shadow_off { create_jobs(:unicode) }
    end

    it 'observes nothing at sample rate 0' do
      expect(EmojiReactionCapability::NodeSnapshotLoader).not_to receive(:load)

      ClimateControl.modify(on_env.merge(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '0')) { create_jobs(:unicode) }

      expect(recorded).to be_empty
    end

    it 'samples a fraction of operations' do
      allow(Random).to receive(:rand).and_return(0.5, 0.0)

      ClimateControl.modify(on_env.merge(EMOJI_REACTION_RESOLVER_SHADOW_SAMPLE_RATE: '0.1')) do
        create_jobs(:unicode)
        EmojiReaction.where(account: reactor).destroy_all
        create_jobs(:unicode)
      end

      expect(recorded_total(op: 'create')).to eq 1
    end

    [
      ['the Node loader', EmojiReactionCapability::NodeSnapshotLoader, :load],
      ['the comparator', EmojiReactionCapability::ShadowComparator, :compare],
      ['the recorder', EmojiReactionCapability::ShadowRecorder, :increment],
      ['the delivery plan', EmojiReactionCapability::DeliveryPlan, :for_status],
    ].each do |name, target, method|
      it "keeps legacy create and Undo behavior when #{name} raises" do
        baseline = shadow_off { create_jobs(:unicode) }
        EmojiReaction.where(account: reactor).destroy_all

        allow(target).to receive(method).and_raise(RuntimeError, 'shadow boom')
        allow(Rails.logger).to receive(:warn)

        shadow_on do
          expect { create_jobs(:unicode) }.not_to raise_error
          expect(deliveries.pluck(:type, :inbox_url)).to eq baseline.pluck(:type, :inbox_url)
          expect(EmojiReaction.where(account: reactor).count).to eq 1

          expect { undo_jobs(:unicode) }.not_to raise_error
          expect(deliveries.size).to eq 1
          expect(EmojiReaction.where(account: reactor).count).to eq 0
        end
      end
    end

    it 'swallows an unavailable Redis' do
      allow(RedisConfiguration).to receive(:with).and_raise(Redis::CannotConnectError)

      shadow_on { expect { create_jobs(:unicode) }.not_to raise_error }

      expect(deliveries.size).to eq 1
    end

    it 'logs a failure at most once per minute per error class and never logs ids, domains or emoji' do
      allow(EmojiReactionCapability::NodeSnapshotLoader).to receive(:load).and_raise(RuntimeError, "boom #{domain} 👍")
      allow(Rails.logger).to receive(:warn)
      EmojiReactionCapability::Shadow.instance_variable_set(:@last_warned, nil)

      shadow_on do
        create_jobs(:unicode)
        EmojiReaction.where(account: reactor).destroy_all
        create_jobs(:unicode)
      end

      expect(Rails.logger).to have_received(:warn).once
      expect(Rails.logger).to have_received(:warn).with('[EmojiReactionCapability::Shadow] create observation failed: RuntimeError')
      expect(counters).to include('err|op=create' => 2)
    end

    it 'writes no per-account, per-status, per-domain or emoji value to the counters' do
      shadow_on do
        create_jobs(:unicode)
        EmojiReaction.where(account: reactor).destroy_all
        create_jobs(:custom)
      end

      text = counters.keys.join(' ')

      expect(text).to include('cmp|')
      [domain, author.id.to_s, status.id.to_s, '👍', 'coolcat', author.username].each do |forbidden|
        expect(text).not_to include(forbidden)
      end
    end
  end

  describe 'query budget' do
    it 'adds one narrow Node read per sampled create and nothing when off' do
      make_node(info: { 'emoji_reaction_type' => 'custom' })

      shadow_off { EmojiReactionService.new.call(reactor, status, '👍') } # warm caches
      EmojiReaction.where(account: reactor).destroy_all
      off = capture_sql { shadow_off { EmojiReactionService.new.call(reactor, status, '👍') } }
      EmojiReaction.where(account: reactor).destroy_all
      on = capture_sql { shadow_on { EmojiReactionService.new.call(reactor, status, '👍') } }

      expect(on.size - off.size).to eq 1
      expect(off.grep(/nodeinfo_missing/)).to be_empty
      expect(on.grep(/nodeinfo_missing/).size).to eq 1
      expect(on.grep(/nodeinfo_missing/).first).not_to match(/"nodes"\."nodeinfo"(?! IS| ->>)/)
    end

    it 'adds one narrow Node read per sampled Undo' do
      make_node(info: { 'emoji_reaction_type' => 'custom' })

      shadow_off { create_jobs(:unicode) }
      shadow_off { undo_jobs(:unicode) } # warm caches
      shadow_off { create_jobs(:unicode) }
      off = capture_sql { shadow_off { UnEmojiReactionService.new.call(reactor, status, '👍', shortcode_only: true) } }
      shadow_off { create_jobs(:unicode) }
      on = capture_sql { shadow_on { UnEmojiReactionService.new.call(reactor, status, '👍', shortcode_only: true) } }

      expect(on.size - off.size).to eq 1
    end
  end

  describe 'local-author fan-out' do
    let(:local_author) { Fabricate(:account, username: 'localauthor') }
    let(:local_status) { Fabricate(:status, account: local_author, visibility: :public) }
    let(:unicode_reaction) { EmojiReaction.create!(account: reactor, status: local_status, name: '👍') }
    let(:other_local_status) { Fabricate(:status, account: local_author, visibility: :public) }
    let(:custom_reaction) { EmojiReaction.create!(account: reactor, status: other_local_status, name: 'coolcat', custom_emoji: custom_emoji) }

    fanout_nodes = {
      'a-custom.example' => { info: { 'emoji_reaction_type' => 'custom', 'favourite' => true } },
      'b-unicode.example' => { info: { 'emoji_reaction_type' => 'unicode', 'favourite' => true } },
      'c-none.example' => { info: { 'emoji_reaction_type' => 'none', 'favourite' => true } },
      'd-birds.example' => { info: { 'upstream_name' => 'birdsitelive', 'emoji_reaction_type' => 'none', 'emoji_reaction_max' => 0, 'favourite' => 'none' } },
      'e-empty.example' => { info: {} },
      'f-missing.example' => { info: { 'emoji_reaction_type' => 'custom', 'favourite' => true }, nodeinfo: { 'error' => 'missing' } },
      'g-norow.example' => nil,
    }.freeze

    def add_follower(node_domain, username, node_attrs)
      follower = Fabricate(:account, username: username, domain: node_domain, protocol: :activitypub, inbox_url: "https://#{node_domain}/inbox", uri: "https://#{node_domain}/u")
      Follow.create!(account: follower, target_account: reactor)
      return unless node_attrs

      Node.create!(domain: node_domain, info: node_attrs[:info], nodeinfo: node_attrs.fetch(:nodeinfo, { 'a' => 1 }), last_fetched_at: Time.now.utc)
    end

    before do
      custom_emoji
      fanout_nodes.each_with_index { |(node_domain, attrs), i| add_follower(node_domain, "follower#{i}", attrs) }
    end

    def distribute(reaction, action)
      ActivityPub::DeliveryWorker.jobs.clear
      ActivityPub::CustomEmojiDistributionWorker.new.perform(reaction.id, action)
      deliveries.map { |d| [d[:inbox_url].delete_prefix('https://').delete_suffix('/inbox'), d[:type]] }.sort
    end

    it 'sends today\'s audience and types with the flag OFF (legacy parity, including the NULL-type difference)' do
      shadow_off do
        expect(distribute(unicode_reaction, 'create')).to eq [
          ['a-custom.example', 'Like'],
          ['b-unicode.example', 'EmojiReact'],
          ['f-missing.example', 'Like'],
        ]

        expect(distribute(custom_reaction, 'create')).to eq [
          ['a-custom.example', 'Like'],
          ['b-unicode.example', 'Like'],
          ['f-missing.example', 'Like'],
        ]
      end

      expect(counters).to be_empty
    end

    it 'sends the same recipients and payload types with the flag ON' do
      off = shadow_off { [distribute(unicode_reaction, 'create'), distribute(custom_reaction, 'delete')] }
      on = shadow_on { [distribute(unicode_reaction, 'create'), distribute(custom_reaction, 'delete')] }

      expect(on).to eq off
    end

    it 'records legacy versus proposed per sampled receiver for a unicode emoji' do
      shadow_on { distribute(unicode_reaction, 'create') }

      expected = {
        %w(native Like EmojiReact diff) => 1,
        %w(native EmojiReact EmojiReact match) => 1,
        %w(like_fallback none Like diff) => 1,
        %w(unsupported_node none none match) => 1,
        %w(unknown_type none Like diff) => 1,
        %w(unknown_nodeinfo_missing Like Like match) => 1,
        %w(unknown_no_row none Like diff) => 1,
      }

      actual = recorded.each_with_object(Hash.new(0)) do |(key, count), h|
        expect(key).to include(op: 'fanout_create', kind: 'unicode')
        h[[key[:basis], key[:legacy], key[:proposed], key[:result]]] += count
      end

      expect(actual).to eq expected
    end

    it 'records legacy versus proposed for a custom emoji and for the delete action' do
      shadow_on { distribute(custom_reaction, 'delete') }

      expect(recorded.keys.pluck(:op).uniq).to eq ['fanout_delete']
      expect(recorded_total(kind: 'custom', basis: 'unicode_only_custom', legacy: 'Like', proposed: 'Like', result: 'match')).to eq 1
      expect(recorded_total(kind: 'custom', basis: 'unknown_type', legacy: 'none', proposed: 'Like', result: 'diff')).to eq 1
      expect(recorded_total(kind: 'custom', basis: 'unknown_no_row', legacy: 'none', proposed: 'Like', result: 'diff')).to eq 1
      expect(recorded_total).to eq 7
    end

    it 'records the Node snapshot distribution for receivers' do
      shadow_on { distribute(unicode_reaction, 'create') }

      summary = EmojiReactionCapability::ShadowReport.summarize(counters.select { |f, _| f.start_with?('snap|') })

      expect(summary[:nodes]).to eq('known' => 4, 'unknown_type' => 1, 'nodeinfo_missing' => 1, 'no_row' => 1)
      expect(summary[:flags]).to include(stale_ignored: 1)
      expect(summary[:families]['birdsitelive']).to eq 1
    end

    it 'samples at most the bounded receiver count with LIMIT queries and never walks the worker UNION' do
      stub_const('EmojiReactionCapability::ShadowConfig::FANOUT_RECEIVER_SAMPLE', 5)
      30.times { |i| add_follower("bulk#{i}.example", "bulk#{i}", { info: { 'emoji_reaction_type' => 'custom' } }) }

      shadow_off { distribute(unicode_reaction, 'create') } # warm caches
      off = capture_sql { shadow_off { distribute(unicode_reaction, 'create') } }
      on = capture_sql { shadow_on { distribute(unicode_reaction, 'create') } }

      expect(on.size - off.size).to eq 3
      expect(on.grep(/nodeinfo_missing/).first).to match(/LIMIT/)
      expect(on.select { |sql| sql.include?('"follows"') && sql.include?('LIMIT') }.size).to be >= 1
      expect(recorded_total).to eq 5
    end

    it 'adds the same three queries for 7 receivers as for 37 (no N+1)' do
      shadow_off { distribute(unicode_reaction, 'create') } # warm caches
      small = capture_sql { shadow_on { distribute(unicode_reaction, 'create') } }.size - capture_sql { shadow_off { distribute(unicode_reaction, 'create') } }.size

      stub_const('EmojiReactionCapability::ShadowConfig::FANOUT_RECEIVER_SAMPLE', 100)
      30.times { |i| add_follower("n#{i}.example", "n#{i}", { info: { 'emoji_reaction_type' => 'unicode' } }) }
      large = capture_sql { shadow_on { distribute(unicode_reaction, 'create') } }.size - capture_sql { shadow_off { distribute(unicode_reaction, 'create') } }.size

      expect([small, large]).to eq [3, 3]
    end

    it 'does not evaluate the worker UNION of audiences' do
      shadow_off { distribute(unicode_reaction, 'create') } # warm caches
      sqls = capture_sql { shadow_on { distribute(unicode_reaction, 'create') } }
      shadow_sqls = sqls.select { |sql| sql.include?('nodeinfo_missing') || sql.include?('LIMIT') }

      expect(shadow_sqls.grep(/UNION/)).to be_empty
    end

    %w(public unlisted private limited direct personal).each do |visibility|
      it "samples the same receivers the worker would use for #{visibility} statuses" do
        mentioned = Fabricate(:account, username: "mentioned#{visibility}", domain: 'mentioned.example', protocol: :activitypub, inbox_url: 'https://mentioned.example/inbox', uri: 'https://mentioned.example/u')
        status = Fabricate(:status, account: local_author, visibility: visibility)
        Mention.create!(status: status, account: mentioned)
        reaction = EmojiReaction.create!(account: reactor, status: status, name: '👍')

        worker = ActivityPub::CustomEmojiDistributionWorker.new
        worker.instance_variable_set(:@emoji_reaction, reaction)
        worker.instance_variable_set(:@status, status)
        worker.instance_variable_set(:@account, reactor)

        expect(EmojiReactionCapability::Shadow.fanout_receiver_ids(reaction)).to match_array(worker.send(:receivers).pluck(:id))
      end
    end

    it 'records nothing for a status without receivers' do
      reaction = EmojiReaction.create!(account: reactor, status: Fabricate(:status, account: Fabricate(:account, username: 'nobody'), visibility: :direct), name: '👍')

      shadow_on { ActivityPub::CustomEmojiDistributionWorker.new.perform(reaction.id, 'create') }

      expect(recorded).to be_empty
    end

    it 'keeps the legacy fan-out when the shadow raises' do
      allow(EmojiReactionCapability::DeliveryPlan).to receive(:for_node).and_raise(RuntimeError)
      allow(Rails.logger).to receive(:warn)

      baseline = shadow_off { distribute(unicode_reaction, 'create') }
      result = shadow_on { distribute(unicode_reaction, 'create') }

      expect(result).to eq baseline
      expect(counters).to include('err|op=fanout_create' => 1)
    end
  end
end
# rubocop:enable Metrics/BlockLength
