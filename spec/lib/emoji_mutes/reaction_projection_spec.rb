# frozen_string_literal: true

require 'rails_helper'

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
    EmojiMutes::Repository.new(user).create({
      'emoji' => emoji,
      'effects' => {
        'replace_in_text' => false,
        'reject_reactions_to_own_posts' => reject,
        'hide_reactions' => hide,
        'hide_in_picker' => false,
      },
    })
  end

  it 'removes one identity from a mixed name and does not leak across viewers' do
    alice = Fabricate(:account)
    bob = Fabricate(:account)
    cache!([{
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
    }])
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
    EmojiMutes::Store.breakdown_loads = 0
    stub_const('EmojiMutes::IdentityBreakdown::MAX_STATUSES', 0)
    capped = described_class.for(status, viewer_user.account, user: viewer_user)
    expect(capped.groups.first['account_ids']).to eq [reactor.id.to_s, other.id.to_s]

    EmojiMutes::Store.breakdowns = nil
    EmojiMutes::Store.breakdown_loads = 0
    EmojiMutes::Store.rule_sets = nil
    stub_const('EmojiMutes::IdentityBreakdown::MAX_STATUSES', 80)
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].match?(/emoji_reactions|emoji_mutes/i)
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      EmojiMutes::IdentityBreakdown.prepare([status, Fabricate(:status)], viewer_user)
      3.times { described_class.for(status, viewer_user.account, user: viewer_user) }
    end
    projected = described_class.for(status, viewer_user.account, user: viewer_user)
    expect(projected.groups.first['account_ids']).to eq [reactor.id.to_s]
    expect(projected.count).to eq 1
    expect(status.status_stat.reload.emoji_reactions_cache).to eq original
    reaction_reads = queries.count { |sql| sql.match?(/from "?emoji_reactions"?/i) && !sql.match?(/emoji_reactions_cache/i) }
    mute_reads = queries.count { |sql| sql.match?(/from "?emoji_mutes"?/i) }
    expect(reaction_reads).to eq 1
    expect(mute_reads).to eq 1
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
