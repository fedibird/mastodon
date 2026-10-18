# frozen_string_literal: true

require 'rails_helper'

describe TimelineSeek::Resolver do
  subject { described_class.new(viewer, user: viewer.user) }

  let(:viewer) { Fabricate(:user).account }
  let(:author) { Fabricate(:user).account }

  def context_for(account, **extra)
    {
      account_id: account.id.to_s,
      exclude_replies: false,
      exclude_reblogs: false,
      tagged: '',
      only_media: false,
    }.merge(extra)
  end

  def resolve(account, status_id, **extra)
    subject.call(
      version: 1,
      source: 'account',
      kind: extra.delete(:kind) || 'status',
      preference: 'nearest',
      context: context_for(account, **extra),
      seek_target: { id: status_id.to_s }
    )
  end

  def capture_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      sqls << payload[:sql] if payload[:sql].include?('statuses')
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'resolves a public post and keeps a very large id as text' do
    snowflake = Mastodon::Snowflake.id_at(Time.utc(2024, 5, 1), with_random: false)
    status = Fabricate(:status, account: author, id: snowflake, created_at: Time.utc(2024, 5, 1), updated_at: Time.utc(2024, 5, 1), visibility: :public)
    result = nil
    sqls = capture_sql { result = resolve(author, status.id) }

    expect(status.id).to be > (10**16)
    expect(result.outcome).to eq('resolved')
    expect(result.capability).to eq('supported')
    expect(result.anchor_id).to eq(snowflake.to_s)
    expect(result.display_row_id).to eq(snowflake.to_s)
    expect(result.to_h[:anchor_id]).to be_a(String)
    point = sqls.find { |sql| sql.match?(/LIMIT/i) && sql.include?('account_id') }
    expect(point).to be_present
    expect(point).not_to include(status.text)
  end

  it 'uses the boost wrapper id and does not seek the original' do
    original = Fabricate(:status, account: viewer, visibility: :public, text: 'original-body')
    boost = Fabricate(:status, account: author, reblog: original, text: '')

    kept = resolve(author, boost.id, exclude_reblogs: false)
    hidden = resolve(author, boost.id, exclude_reblogs: true)
    original_on_booster = resolve(author, original.id, exclude_reblogs: false)

    expect(kept.outcome).to eq('resolved')
    expect(kept.anchor_id).to eq(boost.id.to_s)
    expect(kept.anchor_id).not_to eq(original.id.to_s)
    expect(hidden.outcome).to eq('not_in_source')
    expect(original_on_booster.outcome).to eq('not_in_source')
    expect(kept.to_h.to_json).not_to include('original-body')
  end

  it 'includes a quote, a reference, and a reply that quotes or references only when replies are included' do
    other = Fabricate(:account)
    quoted = Fabricate(:status, account: other, visibility: :public)
    referenced = Fabricate(:status, account: other, visibility: :public)
    parent = Fabricate(:status, account: other, visibility: :public)
    quote = Fabricate(:status, account: author, visibility: :public, quote: quoted, text: 'quote-body')
    reference = Fabricate(:status, account: author, visibility: :public, text: 'reference-body')
    Fabricate(:status_reference, status_id: reference.id, target_status_id: referenced.id)
    reply_quote = Fabricate(:status, account: author, visibility: :public, thread: parent, quote: quoted, text: 'reply-quote-body')
    reply_reference = Fabricate(:status, account: author, visibility: :public, thread: parent, text: 'reply-reference-body')
    Fabricate(:status_reference, status_id: reply_reference.id, target_status_id: referenced.id)

    expect(resolve(author, quote.id, exclude_replies: true).outcome).to eq('resolved')
    expect(resolve(author, reference.id, exclude_replies: true).outcome).to eq('resolved')
    expect(resolve(author, reply_quote.id, exclude_replies: true).outcome).to eq('not_in_source')
    expect(resolve(author, reply_reference.id, exclude_replies: true).outcome).to eq('not_in_source')
    expect(resolve(author, reply_quote.id, exclude_replies: false).anchor_id).to eq(reply_quote.id.to_s)
    expect(resolve(author, reply_reference.id, exclude_replies: false).anchor_id).to eq(reply_reference.id.to_s)
  end

  it 'keeps a self-reply when replies to other accounts are excluded' do
    parent = Fabricate(:status, account: author, visibility: :public)
    self_reply = Fabricate(:status, account: author, thread: parent, visibility: :public)

    expect(resolve(author, self_reply.id, exclude_replies: true).outcome).to eq('resolved')
  end

  it 'separates tagged and media filters from the unfiltered account' do
    tag = Fabricate(:tag, name: 'photos')
    tagged = Fabricate(:status, account: author, visibility: :public, text: 'tagged-body')
    tagged.tags << tag
    media = Fabricate(:status, account: author, visibility: :public)
    Fabricate(:media_attachment, account: author, status: media)
    plain = Fabricate(:status, account: author, visibility: :public, text: 'plain-body')

    expect(resolve(author, tagged.id, tagged: 'photos').outcome).to eq('resolved')
    expect(resolve(author, plain.id, tagged: 'photos').outcome).to eq('not_in_source')
    expect(resolve(author, media.id, only_media: true).outcome).to eq('resolved')
    expect(resolve(author, plain.id, only_media: true).outcome).to eq('not_in_source')
    expect(resolve(author, tagged.id, tagged: 'missing-tag').outcome).to eq('not_in_source')
  end

  it 'does not reveal followers-only, limited, personal, direct, or another account private text' do
    followers = Fabricate(:status, account: author, visibility: :private, text: 'followers-secret')
    limited = Fabricate(:status, account: author, visibility: :limited, text: 'limited-secret')
    personal = Fabricate(:status, account: author, visibility: :personal, text: 'personal-secret')
    direct = Fabricate(:status, account: author, visibility: :direct, text: 'direct-secret')

    [followers, limited, personal, direct].each do |status|
      result = resolve(author, status.id)
      expect(result.outcome).to eq('not_found')
      expect(result.anchor_id).to be_nil
      expect(result.to_h.to_json).not_to include(status.text)
    end

    swapped = resolve(viewer, followers.id)
    expect(swapped.outcome).to eq('not_found')
    expect(swapped.to_h.to_json).not_to include('followers-secret')
  end

  it 'resolves a followers-only post for a follower and a personal post for its author' do
    viewer.follow!(author)
    followers = Fabricate(:status, account: author, visibility: :private)
    expect(resolve(author, followers.id).outcome).to eq('resolved')

    own_limited = Fabricate(:status, account: viewer, visibility: :limited, text: 'own-limited')
    expect(resolve(viewer, own_limited.id).outcome).to eq('resolved')

    own = Fabricate(:status, account: viewer, visibility: :personal, text: 'own-personal')
    expect(resolve(viewer, own.id).outcome).to eq('resolved')

    viewer.user.settings.hide_personal_from_account = true
    hidden = described_class.new(viewer, user: viewer.user).call(
      version: 1,
      source: 'account',
      kind: 'status',
      preference: 'nearest',
      context: context_for(viewer),
      seek_target: { id: own.id.to_s }
    )
    expect(hidden.outcome).to eq('not_visible')
    expect(hidden.reason).to eq('viewer_filter')
    expect(hidden.to_h.to_json).not_to include('own-personal')
  end

  it 'hides deleted, expired, blocked, muted, and suspended rows without their text' do
    deleted = Fabricate(:status, account: author, visibility: :public, text: 'deleted-secret')
    deleted.discard
    expired = Fabricate(:status, account: author, visibility: :public, text: 'expired-secret')
    expired.update_columns(expired_at: 1.hour.ago)
    blocked = Fabricate(:status, account: author, visibility: :public, text: 'blocked-secret')
    author.block!(viewer)
    muted_author = Fabricate(:user).account
    muted = Fabricate(:status, account: muted_author, visibility: :public, text: 'muted-secret')
    viewer.mute!(muted_author)
    suspended_author = Fabricate(:user).account
    suspended = Fabricate(:status, account: suspended_author, visibility: :public, text: 'suspended-secret')
    suspended_author.update_column(:suspended_at, Time.now.utc)

    expect(resolve(author, deleted.id).outcome).to eq('not_found')
    expect(resolve(author, expired.id).outcome).to eq('not_found')
    expect(resolve(author, blocked.id).outcome).to eq('not_found')
    expect(resolve(muted_author, muted.id).outcome).to eq('not_visible')
    blocked_by_viewer = Fabricate(:user).account
    viewer_blocked = Fabricate(:status, account: blocked_by_viewer, visibility: :public, text: 'viewer-block-secret')
    viewer.block!(blocked_by_viewer)
    expect(resolve(blocked_by_viewer, viewer_blocked.id).outcome).to eq('not_visible')
    remote_blocked = Fabricate(:account, domain: 'blocked.example', username: 'blocked')
    domain_row = Fabricate(:status, account: remote_blocked, visibility: :public, text: 'domain-block-secret')
    viewer.block_domain!('blocked.example')
    expect(resolve(remote_blocked, domain_row.id).outcome).to eq('not_found')
    expect(resolve(suspended_author, suspended.id).outcome).to eq('unavailable')
    expect(resolve(suspended_author, suspended.id).reason).to eq('account_unavailable')

    payload = [
      resolve(author, deleted.id),
      resolve(author, expired.id),
      resolve(author, blocked.id),
      resolve(muted_author, muted.id),
      resolve(blocked_by_viewer, viewer_blocked.id),
      resolve(remote_blocked, domain_row.id),
      resolve(suspended_author, suspended.id),
    ].map { |result| result.to_h.to_json }.join
    expect(payload).not_to include('deleted-secret', 'expired-secret', 'blocked-secret', 'muted-secret', 'suspended-secret', 'viewer-block-secret', 'domain-block-secret')
  end

  it 'applies an account hide filter and ignores a home-only filter' do
    hidden = Fabricate(:status, account: author, visibility: :public, text: 'hide-keyword secret-body')
    warned = Fabricate(:status, account: author, visibility: :public, text: 'warn-keyword visible-body')
    home_only = Fabricate(:status, account: author, visibility: :public, text: 'home-keyword visible')
    hide = Fabricate(:custom_filter, account: viewer, phrase: 'hide-keyword', context: %w(account), action: :hide)
    Fabricate(:custom_filter_keyword, custom_filter: hide, keyword: 'hide-keyword', whole_word: false)
    warn = Fabricate(:custom_filter, account: viewer, phrase: 'warn-keyword', context: %w(account), action: :warn)
    Fabricate(:custom_filter_keyword, custom_filter: warn, keyword: 'warn-keyword', whole_word: false)
    home = Fabricate(:custom_filter, account: viewer, phrase: 'home-keyword', context: %w(home), action: :hide)
    Fabricate(:custom_filter_keyword, custom_filter: home, keyword: 'home-keyword', whole_word: false)

    expect(resolve(author, hidden.id).outcome).to eq('not_visible')
    expect(resolve(author, hidden.id).reason).to eq('viewer_filter')
    expect(resolve(author, warned.id).outcome).to eq('resolved')
    expect(resolve(author, home_only.id).outcome).to eq('resolved')
    expect(resolve(author, hidden.id).to_h.to_json).not_to include('hide-keyword', 'secret-body')
  end

  it 'does not treat a missing remote post as absent, and reports a missing local id as not found' do
    remote = Fabricate(:account, domain: 'gap.example', username: 'gap')
    missing = Mastodon::Snowflake.id_at(Time.utc(2024, 6, 1), with_random: false)
    remote_gap = resolve(remote, missing)
    local_gap = resolve(author, missing)

    expect(remote_gap.outcome).to eq('unavailable')
    expect(remote_gap.reason).to eq('not_loaded')
    expect(remote_gap.anchor_id).to be_nil
    expect(local_gap.outcome).to eq('not_found')
  end

  it 'leaves date, account probe, and search unsupported' do
    status = Fabricate(:status, account: author, visibility: :public, text: 'search-secret')

    date = subject.call(version: 1, source: 'account', kind: 'date', preference: 'nearest', context: context_for(author), seek_target: { at: status.created_at.iso8601 })
    account_kind = subject.call(version: 1, source: 'account', kind: 'account', preference: 'nearest', context: context_for(author), seek_target: { account_id: author.id.to_s })
    search = subject.call(version: 1, source: 'account', kind: 'searchHit', preference: 'nearest', context: context_for(author), seek_target: { id: status.id.to_s }, reject_search_text: true)

    expect(date.reason).to eq('date_seek_not_implemented')
    expect(account_kind.reason).to eq('account_probe_not_implemented')
    expect(search.reason).to eq('search_text_not_accepted')
    expect([date, account_kind, search].map { |result| result.to_h.to_json }.join).not_to include('search-secret')
  end

  it 'classifies membership with the same visibility outcomes and a bounded id query' do
    visible = Fabricate(:status, account: author, visibility: :public)
    secret = Fabricate(:status, account: author, visibility: :direct, text: 'membership-secret')
    remote = Fabricate(:account, domain: 'member.example', username: 'member')
    missing = Mastodon::Snowflake.id_at(Time.utc(2024, 7, 1), with_random: false)
    result = nil
    sqls = capture_sql do
      result = TimelineSeek::Membership.new(viewer, user: viewer.user).call(
        version: 1,
        source: 'account',
        context: context_for(author),
        ids: [visible.id.to_s, secret.id.to_s, missing.to_s]
      )
    end
    remote_result = TimelineSeek::Membership.new(viewer, user: viewer.user).call(
      version: 1,
      source: 'account',
      context: context_for(remote),
      ids: [missing.to_s]
    )

    rows = result.to_h[:results].index_by { |row| row[:id] }
    expect(result.outcome).to eq('complete')
    expect(rows[visible.id.to_s][:outcome]).to eq('member')
    expect(rows[secret.id.to_s][:outcome]).to eq('not_found')
    expect(rows[missing.to_s][:outcome]).to eq('not_found')
    expect(remote_result.to_h[:results].first).to include(outcome: 'unknown', reason: 'not_loaded')
    expect(result.to_h.to_json).not_to include('membership-secret')
    expect(sqls.join("\n")).to match(/LIMIT/i)
  end
end
