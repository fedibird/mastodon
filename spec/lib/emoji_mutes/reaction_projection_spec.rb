# frozen_string_literal: true

require 'rails_helper'

# These integration examples share cache and viewer fixtures across scenarios.
# rubocop:disable Metrics/BlockLength
RSpec.describe EmojiMutes::ReactionProjection do
  let(:author) { Fabricate(:account) }
  let(:viewer_user) { Fabricate(:user) }
  let(:other_user) { Fabricate(:user) }
  let(:status) { Fabricate(:status, account: author) }
  let(:local_emoji) { Fabricate(:custom_emoji, shortcode: 'blob') }
  let(:remote_emoji) { Fabricate(:custom_emoji, shortcode: 'blob', domain: 'other.example') }

  def cache!(payload)
    stat = StatusStat.find_or_initialize_by(status: status)
    stat.update!(emoji_reactions_cache: Oj.dump(payload), emoji_reactions_count: 4, emoji_reactions_cache_dirty: false)
    status.association(:status_stat).reset
  end

  def mute(user, emoji, hide: true, reject: false)
    body = {
      'emoji' => emoji,
      'effects' => {
        'replace_in_text' => false,
        'reject_reactions_to_own_posts' => reject,
        'hide_reactions' => hide,
        'hide_in_picker' => false,
      },
    }
    EmojiMutes::Repository.new(user).create(body)
  end

  it 'keeps a legacy custom cache until a hide exists, then removes only that identity' do
    alice = Fabricate(:account)
    bob = Fabricate(:account, domain: 'other.example')
    EmojiReaction.create!(account: alice, status: status, name: 'blob', custom_emoji: local_emoji)
    EmojiReaction.create!(account: bob, status: status, name: 'blob', custom_emoji: remote_emoji)
    cached = [{
      'name' => 'blob',
      'count' => 2,
      'account_ids' => [alice.id.to_s, bob.id.to_s],
      'url' => 'https://example.test/local.png',
      'static_url' => 'https://example.test/local-static.png',
      'domain' => nil,
    }]
    cache!(cached)

    open_status = REST::StatusSerializer.new(status, scope: viewer_user, scope_name: :current_user)
    expect(open_status.emoji_reactions.first).not_to have_key('parts')
    expect(open_status.emoji_reactions.first['account_ids']).to eq [alice.id.to_s, bob.id.to_s]
    expect(open_status.emoji_reactions_count).to eq 2

    mute(viewer_user, { 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => local_emoji.id.to_s })
    EmojiMutes::Store.rule_sets = nil
    EmojiMutes::Store.breakdowns = nil
    muted = REST::StatusSerializer.new(status, scope: viewer_user, scope_name: :current_user)
    expect(muted.emoji_reactions_count).to eq 1
    expect(muted.emoji_reactions.first['account_ids']).to eq [bob.id.to_s]
    expect(muted.emoji_reactions.first['domain']).to eq 'other.example'
    expect(status.status_stat.reload.emoji_reactions_cache).not_to include('parts')
  end

  it 'removes one identity from a mixed name and does not leak across viewers' do
    alice = Fabricate(:account)
    bob = Fabricate(:account)
    cached = [{
      'name' => 'blob',
      'count' => 2,
      'account_ids' => [alice.id.to_s, bob.id.to_s],
      'url' => 'https://example.test/local.png',
      'static_url' => 'https://example.test/local-static.png',
      'domain' => nil,
      'parts' => [
        {
          'identity' => { 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => local_emoji.id.to_s },
          'custom_emoji_id' => local_emoji.id.to_s,
          'account_ids' => [alice.id.to_s],
          'count' => 1,
          'url' => 'https://example.test/local.png',
          'static_url' => 'https://example.test/local-static.png',
          'domain' => nil,
        },
        {
          'identity' => { 'kind' => 'custom', 'scope' => 'remote', 'domain' => 'other.example', 'shortcode' => 'blob' },
          'custom_emoji_id' => remote_emoji.id.to_s,
          'account_ids' => [bob.id.to_s],
          'count' => 1,
          'url' => 'https://example.test/remote.png',
          'static_url' => 'https://example.test/remote-static.png',
          'domain' => 'other.example',
        },
      ],
    }]
    cache!(cached)
    mute(viewer_user, { 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => local_emoji.id.to_s })
    mute(other_user, { 'kind' => 'custom', 'scope' => 'remote', 'domain' => 'other.example', 'shortcode' => 'blob' })

    first = REST::StatusSerializer.new(status, scope: viewer_user, scope_name: :current_user)
    expect(first.emoji_reactions_count).to eq 1
    expect(first.emoji_reactions.first['account_ids']).to eq [bob.id.to_s]
    expect(first.emoji_reactions.first['domain']).to eq 'other.example'
    expect(first.emoji_reactions.first['count']).to eq first.emoji_reactions_count

    second = REST::StatusSerializer.new(status, scope: other_user, scope_name: :current_user)
    expect(second.emoji_reactions_count).to eq 1
    expect(second.emoji_reactions.first['account_ids']).to eq [alice.id.to_s]
    expect(second.emoji_reactions.first['domain']).to be_nil

    anonymous = REST::StatusSerializer.new(status, scope: nil, scope_name: :current_user)
    expect(anonymous.emoji_reactions_count).to eq 2
    expect(anonymous.emoji_reactions.first['account_ids']).to eq [alice.id.to_s, bob.id.to_s]
    expect(status.instance_variable_get(:@emoji_reactions_count)).to be_nil
    expect(status.status_stat.emoji_reactions_count).to eq 4
    expect(Oj.load(status.status_stat.emoji_reactions_cache).first['count']).to eq 2
  end

  it 'does not hide a legacy mixed group from its representative, then projects a batched read' do
    reactor = Fabricate(:account)
    other = Fabricate(:account)
    EmojiReaction.create!(account: reactor, status: status, name: 'blob', custom_emoji: local_emoji)
    EmojiReaction.create!(account: other, status: status, name: 'blob', custom_emoji: remote_emoji)
    legacy = [{
      'name' => 'blob',
      'count' => 2,
      'account_ids' => [reactor.id.to_s, other.id.to_s],
      'domain' => 'other.example',
      'url' => 'https://example.test/remote.png',
    }]
    cache!(legacy)
    original = status.status_stat.emoji_reactions_cache
    mute(viewer_user, { 'kind' => 'custom', 'scope' => 'remote', 'domain' => 'other.example', 'shortcode' => 'blob' })

    EmojiMutes::Store.breakdowns = nil
    EmojiMutes::Store.rule_sets = nil
    stub_const('EmojiMutes::IdentityBreakdown::QUERY_BATCH', 1)
    extras = Array.new(2) do
      extra = Fabricate(:status)
      actor = Fabricate(:account)
      EmojiReaction.create!(account: actor, status: extra, name: 'blob', custom_emoji: remote_emoji)
      cache = [{ 'name' => 'blob', 'count' => 1, 'account_ids' => [actor.id.to_s], 'domain' => 'other.example', 'url' => 'https://example.test/remote.png' }]
      stat = StatusStat.find_or_initialize_by(status: extra)
      stat.update!(emoji_reactions_cache: Oj.dump(cache), emoji_reactions_count: 1, emoji_reactions_cache_dirty: false)
      extra.association(:status_stat).reset
      extra
    end
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].match?(/emoji_reactions|emoji_mutes/i)
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      EmojiMutes::IdentityBreakdown.prepare([status] + extras, viewer_user)
      3.times { described_class.for(status, viewer_user.account, user: viewer_user) }
    end
    projected = described_class.for(status, viewer_user.account, user: viewer_user)
    expect(projected.groups.first['account_ids']).to eq [reactor.id.to_s]
    expect(projected.count).to eq 1
    extras.each do |extra|
      expect(described_class.for(extra, viewer_user.account, user: viewer_user).count).to eq 0
    end
    expect(status.status_stat.reload.emoji_reactions_cache).to eq original
    reaction_reads = queries.count { |sql| sql.match?(/from "?emoji_reactions"?/i) && !sql.match?(/emoji_reactions_cache/i) }
    mute_reads = queries.count { |sql| sql.match?(/from "?emoji_mutes"?/i) }
    expect(reaction_reads).to eq 3
    expect(mute_reads).to eq 1
  end

  it 'checks domain-blocked account ids once for multiple reaction groups on the same status' do
    blocked = Fabricate(:account, domain: 'blocked.example')
    visible = Fabricate(:account, domain: 'visible.example')
    Fabricate(:account_domain_block, account: viewer_user.account, domain: 'blocked.example')
    cached = [
      { 'name' => '👍', 'count' => 2, 'account_ids' => [blocked.id.to_s, visible.id.to_s] },
      { 'name' => '👀', 'count' => 2, 'account_ids' => [blocked.id.to_s, visible.id.to_s] },
    ]
    cache!(cached)

    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      queries << sql if sql.include?('FROM "accounts"') && sql.include?('"accounts"."domain"')
    end

    result = nil
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      result = described_class.for(status, viewer_user.account, user: viewer_user)
    end

    expect(result.groups.map { |group| group['account_ids'] }).to eq [[visible.id.to_s], [visible.id.to_s]]
    expect(result.count).to eq 2
    expect(queries.size).to eq 1
  end

  it 'keeps both identities in a refreshed cache and preserves a part identity' do
    EmojiReaction.create!(account: Fabricate(:account), status: status, name: 'blob', custom_emoji: local_emoji)
    EmojiReaction.create!(account: Fabricate(:account), status: status, name: 'blob', custom_emoji: remote_emoji)
    status.refresh_grouped_emoji_reactions!
    groups = Oj.load(status.status_stat.reload.emoji_reactions_cache, mode: :strict)
    identities = groups.first.fetch('parts').map { |part| part.fetch('identity') }
    expect(identities).to include(
      hash_including('scope' => 'local', 'custom_emoji_id' => local_emoji.id.to_s),
      hash_including('scope' => 'remote', 'domain' => 'other.example', 'shortcode' => 'blob')
    )
    expect(groups.first['count']).to eq 2
  end
end
# rubocop:enable Metrics/BlockLength
