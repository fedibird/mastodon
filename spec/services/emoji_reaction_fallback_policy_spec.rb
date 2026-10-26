# frozen_string_literal: true

require 'rails_helper'

# The gate's label has to be the activity create_notification enqueues.
# DeliveryPlan is not consulted. rubocop:disable Metrics/BlockLength
RSpec.describe 'Emoji reaction fallback policy gate' do
  let(:reactor_user) { Fabricate(:user) }
  let(:reactor) { reactor_user.account }
  let(:enforced) do
    {
      'EMOJI_REACTION_CANONICAL_WRITES' => 'true',
      'EMOJI_REACTION_IDEMPOTENT_RETRY' => 'true',
      'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => 'true',
    }
  end

  around { |example| ClimateControl.modify(enforced) { Sidekiq::Testing.fake! { example.run } } }

  before do
    ActivityPub::DeliveryWorker.jobs.clear
    ActivityPub::CustomEmojiDistributionWorker.jobs.clear
  end

  def policy!(value)
    reactor_user.settings['emoji_reaction_fallback_policy'] = value
  end

  def remote_author(domain, protocol: :activitypub)
    Fabricate(
      :account,
      username: "a#{SecureRandom.hex(3)}",
      domain: domain,
      protocol: protocol,
      inbox_url: "https://#{domain}/inbox",
      uri: "https://#{domain}/users/author"
    )
  end

  def make_node(domain, info, nodeinfo: { 'a' => 1 }, info_override: nil)
    Node.create!(
      domain: domain,
      info: info,
      nodeinfo: nodeinfo,
      info_override: info_override,
      last_fetched_at: Time.now.utc
    )
  end

  def status_for(author)
    Fabricate(:status, account: author, uri: "https://#{author.domain || 'local'}/status/#{SecureRandom.hex(2)}")
  end

  def call_service(status, emoji = '👍', confirmation: nil, actor: reactor)
    EmojiReactionService.new.call(actor, status, emoji, fallback_confirmation: confirmation)
  rescue Mastodon::EmojiReactionPolicyError => error
    error
  end

  def delivery_types
    ActivityPub::DeliveryWorker.jobs.map { |job| JSON.parse(job['args'].first)['type'] }
  end

  def delivery_inboxes
    ActivityPub::DeliveryWorker.jobs.map { |job| job['args'][2] }
  end

  def undo_types
    ActivityPub::DeliveryWorker.jobs.map do |job|
      payload = JSON.parse(job['args'].first)
      payload['type'] == 'Undo' ? payload['object']['type'] : payload['type']
    end
  end

  def rows_for(status)
    EmojiReaction.where(account_id: reactor.id, status_id: status.proper.id).count
  end

  def sql_log
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql].to_s
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries.reject { |sql| sql.include?('SCHEMA') }
  end

  describe 'actual delivery classification' do
    let(:custom_emoji) { Fabricate(:custom_emoji, shortcode: "cat#{SecureRandom.hex(2)}") }

    def prepare(kind)
      domain = "#{kind}-#{SecureRandom.hex(2)}.example"
      author = remote_author(domain)
      case kind
      when :missing
        # no node row
      when :empty_info
        make_node(domain, {})
      when :stale_custom
        make_node(domain, { 'emoji_reaction_type' => 'custom', 'favourite' => true }, nodeinfo: { 'error' => 'missing' })
      when :kmyblue
        make_node(domain, { 'emoji_reaction_type' => 'custom', 'software_name' => 'kmyblue', 'favourite' => true })
      when :kmyblue_case
        make_node(domain, { 'emoji_reaction_type' => 'custom', 'software_name' => 'Kmyblue', 'favourite' => true })
      when :unicode
        make_node(domain, { 'emoji_reaction_type' => 'unicode', 'favourite' => true })
      when :custom
        make_node(domain, { 'emoji_reaction_type' => 'custom', 'favourite' => true })
      when :birdsitelive
        make_node(domain, { 'emoji_reaction_type' => 'none', 'favourite' => 'none', 'software_name' => 'birdsitelive' })
      when :override_ignored
        make_node(domain, { 'emoji_reaction_type' => 'none', 'favourite' => true }, info_override: { 'emoji_reaction_type' => 'custom' })
      end
      status_for(author)
    end

    # code nil means the write succeeded. types is what DeliveryWorker received.
    {
      missing_deny: [:missing, 'deny', '👍', 'capability_unknown_denied', [], 0],
      missing_allow: [:missing, 'allow', '👍', nil, ['Like'], 1],
      empty_deny: [:empty_info, 'deny', '👍', 'capability_unknown_denied', [], 0],
      empty_allow: [:empty_info, 'allow', '👍', nil, ['EmojiReact'], 1],
      stale_deny: [:stale_custom, 'deny', '👍', 'capability_unknown_denied', [], 0],
      stale_allow: [:stale_custom, 'allow', '👍', nil, ['EmojiReact'], 1],
      kmyblue_deny: [:kmyblue, 'deny', '👍', 'fallback_denied', [], 0],
      kmyblue_allow: [:kmyblue, 'allow', '👍', nil, ['Like'], 1],
      kmyblue_case_deny: [:kmyblue_case, 'deny', '👍', nil, ['EmojiReact'], 1],
      unicode_deny: [:unicode, 'deny', '👍', nil, ['EmojiReact'], 1],
      custom_type_deny: [:custom, 'deny', '👍', nil, ['EmojiReact'], 1],
      birdsitelive_deny: [:birdsitelive, 'deny', '👍', 'fallback_denied', [], 0],
      birdsitelive_allow: [:birdsitelive, 'allow', '👍', nil, ['Like'], 1],
      override_deny: [:override_ignored, 'deny', '👍', 'fallback_denied', [], 0],
      override_allow: [:override_ignored, 'allow', '👍', nil, ['Like'], 1],
    }.each do |name, (kind, choice, emoji, code, types, row_count)|
      it "labels #{name} as the legacy send" do
        status = prepare(kind)
        policy!(choice)
        result = call_service(status, emoji)

        actual_code = result.is_a?(Mastodon::EmojiReactionPolicyError) ? result.error_code : nil
        expect(actual_code).to eq(code), name.to_s
        expect(rows_for(status)).to eq row_count
        expect(delivery_types).to eq types
        expect(ActivityPub::CustomEmojiDistributionWorker.jobs).to be_empty
        if code == 'fallback_denied'
          expect(result.details).to eq('mechanism' => 'like_fallback')
          expect(result.http_status).to eq 403
          expect(result.message).to eq 'This action is not allowed'
        elsif code == 'capability_unknown_denied'
          expect(result.details).to be_nil
        end
      end
    end

    it 'labels a custom emoji on a unicode-only node as unknown and still sends EmojiReact when allowed' do
      status = prepare(:unicode)
      policy!('allow')
      expect(call_service(status, custom_emoji.shortcode)).to be_a(EmojiReaction)
      expect(delivery_types).to eq ['EmojiReact']

      EmojiReaction.delete_all
      ActivityPub::DeliveryWorker.jobs.clear
      policy!('deny')
      result = call_service(status, custom_emoji.shortcode)
      expect(result.error_code).to eq 'capability_unknown_denied'
      expect(EmojiReaction.where(name: custom_emoji.shortcode)).to be_empty
      expect(delivery_types).to eq []
    end

    it 'does not apply the policy to a local author, a silenced author, or a non-ActivityPub author' do
      local_author = Fabricate(:user).account
      local_status = Fabricate(:status, account: local_author)
      policy!('deny')
      expect(call_service(local_status)).to be_a(EmojiReaction)
      expect(ActivityPub::CustomEmojiDistributionWorker.jobs.size).to eq 1
      expect(delivery_types).to eq []

      ActivityPub::CustomEmojiDistributionWorker.jobs.clear
      silenced = remote_author('silenced.example')
      make_node('silenced.example', { 'emoji_reaction_type' => 'none', 'favourite' => true })
      silenced.silence!
      silenced_status = status_for(silenced)
      expect(call_service(silenced_status)).to be_a(EmojiReaction)
      expect(delivery_types).to eq []

      other = remote_author('ostatus.example', protocol: :ostatus)
      make_node('ostatus.example', { 'emoji_reaction_type' => 'none', 'favourite' => true })
      other_status = status_for(other)
      expect(call_service(other_status)).to be_a(EmojiReaction)
      expect(delivery_types).to eq []
    end

    it 'uses the original author of a boost, not the booster node' do
      original = remote_author('original.example')
      make_node('original.example', { 'emoji_reaction_type' => 'custom', 'favourite' => true })
      booster = remote_author('booster.example')
      make_node('booster.example', { 'emoji_reaction_type' => 'none', 'favourite' => 'none' })
      original_status = status_for(original)
      wrapper = Fabricate(:status, account: booster, reblog: original_status, text: '')
      policy!('deny')

      expect(call_service(wrapper)).to be_a(EmojiReaction)
      expect(rows_for(original_status)).to eq 1
      expect(rows_for(wrapper)).to eq 1
      expect(delivery_types).to eq ['EmojiReact']
      expect(delivery_inboxes).to eq [original.inbox_url]

      EmojiReaction.delete_all
      ActivityPub::DeliveryWorker.jobs.clear
      fallback_original = remote_author('fallback-original.example')
      make_node('fallback-original.example', { 'emoji_reaction_type' => 'none', 'favourite' => true })
      native_booster = remote_author('native-booster.example')
      make_node('native-booster.example', { 'emoji_reaction_type' => 'custom', 'favourite' => true })
      fallback_status = status_for(fallback_original)
      fallback_wrapper = Fabricate(:status, account: native_booster, reblog: fallback_status, text: '')
      result = call_service(fallback_wrapper)
      expect(result.error_code).to eq 'fallback_denied'
      expect(EmojiReaction.count).to eq 0
      expect(delivery_types).to eq []
    end
  end

  describe 'ask confirmation' do
    let(:domain) { 'ask.example' }
    let(:author) { remote_author(domain) }
    let(:status) { status_for(author) }

    before do
      make_node(domain, { 'emoji_reaction_type' => 'none', 'favourite' => true })
      policy!('ask')
    end

    it 'refuses without a token and accepts the token once' do
      required = call_service(status)
      expect(required.error_code).to eq 'fallback_confirmation_required'
      expect(required.http_status).to eq 409
      expect(required.details.keys).to contain_exactly('mechanism', 'effects', 'confirmation_token', 'expires_in')
      expect(required.message).to eq Mastodon::EmojiReactionPolicyError::CONFIRM_REQUIRED
      expect(required.details['mechanism']).to eq 'like_fallback'
      expect(required.details['effects']).to eq ['remote_favourite']
      expect(required.details['expires_in']).to eq 300
      expect(EmojiReaction.count).to eq 0
      expect(delivery_types).to eq []

      token = required.details['confirmation_token']
      expect(call_service(status, confirmation: token)).to be_a(EmojiReaction)
      expect(rows_for(status)).to eq 1
      expect(delivery_types).to eq ['Like']

      ActivityPub::DeliveryWorker.jobs.clear
      expect(call_service(status, confirmation: token)).to be_a(EmojiReaction)
      expect(delivery_types).to eq []

      EmojiReaction.delete_all
      replay = call_service(status, confirmation: token)
      expect(replay.error_code).to eq 'fallback_confirmation_invalid'
      expect(replay.details['confirmation_token']).not_to eq token
      expect(EmojiReaction.count).to eq 0
      expect(call_service(status, confirmation: replay.details['confirmation_token'])).to be_a(EmojiReaction)
      expect(delivery_types).to eq ['Like']
    end

    it 'describes a favourite only when the queued activity is a Like' do
      missing = status_for(remote_author('missing-ask.example'))
      missing_result = call_service(missing)
      expect(missing_result.error_code).to eq 'fallback_confirmation_required'
      expect(missing_result.message).to eq Mastodon::EmojiReactionPolicyError::CONFIRM_REQUIRED
      expect(missing_result.details['mechanism']).to eq 'unknown'
      expect(missing_result.details['effects']).to eq ['remote_favourite']

      empty_domain = 'empty-ask.example'
      make_node(empty_domain, {})
      empty_result = call_service(status_for(remote_author(empty_domain)))
      expect(empty_result.message).to eq Mastodon::EmojiReactionPolicyError::CONFIRM_REQUIRED_UNKNOWN
      expect(empty_result.details['mechanism']).to eq 'unknown'
      expect(empty_result.details['effects']).to eq []
      expect(empty_result.message).not_to include('favourite')

      unicode_domain = 'unicode-ask.example'
      make_node(unicode_domain, { 'emoji_reaction_type' => 'unicode', 'favourite' => true })
      custom = Fabricate(:custom_emoji, shortcode: "bird#{SecureRandom.hex(2)}")
      custom_result = call_service(status_for(remote_author(unicode_domain)), custom.shortcode)
      expect(custom_result.message).to eq Mastodon::EmojiReactionPolicyError::CONFIRM_REQUIRED_UNKNOWN
      expect(custom_result.details['mechanism']).to eq 'unknown'
      expect(custom_result.details['effects']).to eq []
      expect(custom_result.message).not_to include('favourite')
      expect(EmojiReaction.count).to eq 0
      expect(delivery_types).to eq []
    end

    it 'rejects a token for another user, emoji, status, or a changed node, and does not let it override deny' do
      token = call_service(status).details['confirmation_token']
      other = Fabricate(:user)
      other.settings['emoji_reaction_fallback_policy'] = 'ask'
      wrong_user = call_service(status, confirmation: token, actor: other.account)
      expect(wrong_user.error_code).to eq 'fallback_confirmation_invalid'

      wrong_emoji = call_service(status, '😂', confirmation: token)
      expect(wrong_emoji.error_code).to eq 'fallback_confirmation_invalid'
      expect(wrong_emoji.details['confirmation_token']).not_to eq token
      expect(EmojiReaction.where(name: '😂')).to be_empty

      other_author = remote_author('other-ask.example')
      make_node('other-ask.example', { 'emoji_reaction_type' => 'none', 'favourite' => true })
      wrong_status = call_service(status_for(other_author), confirmation: token)
      expect(wrong_status.error_code).to eq 'fallback_confirmation_invalid'

      Node.find_by(domain: domain).update!(info: { 'emoji_reaction_type' => 'custom', 'favourite' => true })
      expect(call_service(status, confirmation: token)).to be_a(EmojiReaction)
      expect(delivery_types).to eq ['EmojiReact']

      EmojiReaction.delete_all
      ActivityPub::DeliveryWorker.jobs.clear
      Node.find_by(domain: domain).update!(info: { 'emoji_reaction_type' => 'none', 'favourite' => true })
      fresh = call_service(status).details['confirmation_token']
      policy!('deny')
      denied = call_service(status, confirmation: fresh)
      expect(denied.error_code).to eq 'fallback_denied'
      expect(EmojiReaction.count).to eq 0
      expect(delivery_types).to eq []
    end

    it 'spends the token when the insert then fails the cap' do
      previous = Setting.reaction_max_per_account
      Setting.reaction_max_per_account = 1
      policy!('allow')
      expect(call_service(status, '👍')).to be_a(EmojiReaction)
      policy!('ask')
      ActivityPub::DeliveryWorker.jobs.clear
      token = call_service(status, '😂').details['confirmation_token']
      expect { call_service(status, '😂', confirmation: token) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(EmojiReaction.where(name: '😂')).to be_empty
      expect(delivery_types).to eq []

      replay = call_service(status, '😂', confirmation: token)
      expect(replay.error_code).to eq 'fallback_confirmation_invalid'
      expect(EmojiReaction.where(name: '😂')).to be_empty
    ensure
      Setting.reaction_max_per_account = previous if defined?(previous)
    end

    it 'does not insert when Redis fails during redemption' do
      token = call_service(status).details['confirmation_token']
      allow(RedisConfiguration).to receive(:with).and_raise(Redis::ConnectionError)

      result = call_service(status, confirmation: token)
      expect(result).to be_a(Mastodon::EmojiReactionPolicyError)
      expect(result.http_status).to eq 503
      expect(result.error_code).to eq 'fallback_confirmation_unavailable'
      expect(EmojiReaction.count).to eq 0
      expect(delivery_types).to eq []
    end
  end

  describe 'compatibility' do
    let(:domain) { 'compat.example' }
    let(:author) { remote_author(domain) }
    let(:status) { status_for(author) }

    before { make_node(domain, { 'emoji_reaction_type' => 'none', 'favourite' => true }) }

    it 'keeps an existing row idempotent after the policy changes to deny or ask' do
      policy!('allow')
      expect(call_service(status)).to be_a(EmojiReaction)
      expect(delivery_types).to eq ['Like']
      ActivityPub::DeliveryWorker.jobs.clear

      policy!('deny')
      expect(call_service(status)).to be_a(EmojiReaction)
      policy!('ask')
      expect(call_service(status)).to be_a(EmojiReaction)
      expect(rows_for(status)).to eq 1
      expect(delivery_types).to eq []
    end

    it 'still removes a reaction under deny and does not change the Undo type' do
      unicode_domain = 'undo-kmy.example'
      undo_author = remote_author(unicode_domain)
      make_node(unicode_domain, { 'emoji_reaction_type' => 'unicode', 'software_name' => 'kmyblue', 'favourite' => true })
      undo_status = status_for(undo_author)
      policy!('allow')
      expect(call_service(undo_status)).to be_a(EmojiReaction)
      expect(delivery_types).to eq ['Like']
      ActivityPub::DeliveryWorker.jobs.clear

      policy!('deny')
      reactor_user.settings['disable_reactions'] = true
      UnEmojiReactionService.new.call(reactor, undo_status, '👍', shortcode_only: true)
      expect(EmojiReaction.where(account: reactor, status: undo_status)).to be_empty
      expect(undo_types).to eq ['EmojiReact']
    end

    it 'leaves the remote-custom-emoji no-op alone' do
      foreign = Fabricate(:custom_emoji, shortcode: 'bird', domain: 'emoji.example')
      policy!('deny')
      expect(EmojiReactionCapability::FallbackGate).not_to receive(:enforce!)
      expect(call_service(status, "#{foreign.shortcode}@#{foreign.domain}")).to be_nil
      expect(EmojiReaction.count).to eq 0
    end

    it 'rejects a new reaction in the service when enforcement is on and reactions are disabled' do
      reactor_user.settings['disable_reactions'] = true
      policy!('allow')
      queries = sql_log do
        expect { call_service(status) }.to raise_error(Mastodon::NotPermittedError)
      end

      expect(queries.grep(/nodeinfo_missing/)).to be_empty
      expect(EmojiReaction.count).to eq 0
      expect(delivery_types).to eq []
    end

    it 'still creates from the service when enforcement is off, even if reactions are disabled' do
      reactor_user.settings['disable_reactions'] = true
      off = {
        'EMOJI_REACTION_CANONICAL_WRITES' => nil,
        'EMOJI_REACTION_IDEMPOTENT_RETRY' => nil,
        'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => nil,
      }
      ClimateControl.modify(off) do
        expect(call_service(status)).to be_a(EmojiReaction)
      end
      expect(delivery_types).to eq ['Like']
    end

    it 'keeps an existing row when reactions are disabled after it was created' do
      policy!('allow')
      expect(call_service(status)).to be_a(EmojiReaction)
      ActivityPub::DeliveryWorker.jobs.clear
      reactor_user.settings['disable_reactions'] = true

      expect(call_service(status)).to be_a(EmojiReaction)
      expect(rows_for(status)).to eq 1
      expect(delivery_types).to eq []
    end

    it 'refuses a Like when the reactor user cannot be read' do
      orphan = Fabricate(:account)
      result = call_service(status, actor: orphan)
      expect(result.error_code).to eq 'capability_unknown_denied'
      expect(EmojiReaction.count).to eq 0
      expect(delivery_types).to eq []
    end

    it 'runs the external guard before the policy gate' do
      policy!('deny')
      expect(ExternalBridge::Guards).to receive(:reject_target!).and_raise(Mastodon::ValidationError, 'external')
      expect(EmojiReactionCapability::FallbackGate).not_to receive(:enforce!)
      expect { call_service(status) }.to raise_error(Mastodon::ValidationError, 'external')
      expect(EmojiReaction.count).to eq 0
    end

    it 'does not fetch NodeInfo' do
      policy!('deny')
      expect(UpdateNodeService).not_to receive(:new)
      call_service(status)
    end
  end

  describe 'flag matrix and reads' do
    let(:domain) { 'matrix.example' }
    let(:author) { remote_author(domain) }
    let(:status) { status_for(author) }

    before { make_node(domain, { 'emoji_reaction_type' => 'none', 'favourite' => true }) }

    [
      { 'EMOJI_REACTION_CANONICAL_WRITES' => nil, 'EMOJI_REACTION_IDEMPOTENT_RETRY' => nil, 'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => nil },
      { 'EMOJI_REACTION_CANONICAL_WRITES' => 'true', 'EMOJI_REACTION_IDEMPOTENT_RETRY' => nil, 'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => 'true' },
      { 'EMOJI_REACTION_CANONICAL_WRITES' => nil, 'EMOJI_REACTION_IDEMPOTENT_RETRY' => 'true', 'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => 'true' },
      { 'EMOJI_REACTION_CANONICAL_WRITES' => 'true', 'EMOJI_REACTION_IDEMPOTENT_RETRY' => 'true', 'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => nil },
      { 'EMOJI_REACTION_CANONICAL_WRITES' => 'true', 'EMOJI_REACTION_IDEMPOTENT_RETRY' => 'true', 'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => 'TRUE' },
    ].each do |flags|
      it "does not enforce for #{flags.values.inspect}" do
        policy!('deny')
        EmojiReactionCapability::FallbackPolicyConfig.reset_incomplete_warning!
        ClimateControl.modify(flags) do
          expect(EmojiReactionCapability::FallbackGate).not_to receive(:enforce!)
          expect(call_service(status)).to be_a(EmojiReaction)
        end
        expect(delivery_types).to eq ['Like']
      end
    end

    it 'adds no snapshot query or Redis when the gate is off' do
      policy!('deny')
      off = {
        'EMOJI_REACTION_CANONICAL_WRITES' => nil,
        'EMOJI_REACTION_IDEMPOTENT_RETRY' => nil,
        'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => nil,
      }
      queries = nil
      ClimateControl.modify(off) do
        expect(EmojiReactionCapability::FallbackConfirmation).not_to receive(:issue)
        expect(EmojiReactionCapability::FallbackConfirmation).not_to receive(:consume!)
        queries = sql_log { expect(call_service(status)).to be_a(EmojiReaction) }
      end
      expect(queries.grep(/nodeinfo_missing/)).to be_empty
      expect(delivery_types).to eq ['Like']
    end

    it 'reads the node snapshot once when the gate refuses or allows a remote author' do
      policy!('deny')
      denied = sql_log { call_service(status) }
      expect(denied.grep(/nodeinfo_missing/).size).to eq 1
      expect(delivery_types).to eq []

      EmojiReaction.delete_all
      policy!('allow')
      allowed = sql_log { call_service(status) }
      expect(allowed.grep(/nodeinfo_missing/).size).to eq 1
      expect(allowed.grep(/FROM "nodes"/).size).to eq 1
      expect(delivery_types).to eq ['Like']
    end

    it 'still notifies shadow with the activity that was enqueued' do
      policy!('allow')
      expect(EmojiReactionCapability::Shadow).to receive(:observe_create).with(an_instance_of(EmojiReaction), legacy_type: 'Like').and_call_original
      call_service(status)
    end
  end
end
