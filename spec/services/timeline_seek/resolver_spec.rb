# frozen_string_literal: true

require 'rails_helper'

describe TimelineSeek::Resolver do
  subject { described_class.new(viewer, user: viewer.user) }

  let(:viewer) { Fabricate(:user).account }
  let(:author) { Fabricate(:user).account }

  def resolve(source:, kind:, target:, context: {}, preference: 'nearest')
    subject.call(
      version: 1,
      source: source,
      kind: kind,
      preference: preference,
      context: context,
      seek_target: target
    )
  end

  def public_context
    { only_media: false, without_media: false, without_bot: false }
  end

  def place_in_home(account, status)
    redis.zadd(FeedManager.instance.key(:home, account.id), status.id, status.id)
  end

  describe 'capability gate' do
    it 'does not pretend account, direct, notifications, or mix timelines can seek' do
      %w(account direct notifications mix).each do |source|
        result = resolve(source: source, kind: 'status', target: { id: '1' })

        expect(result.outcome).to eq('unsupported')
        expect(result.capability).to eq('unsupported')
        expect(result.reason).to eq('source_has_no_windowed_history')
      end
    end

    it 'rejects a raw search string instead of treating it as a miss' do
      result = subject.call(version: 1, source: 'public', kind: 'searchHit', preference: 'nearest', seek_target: { id: '1', text: 'secret phrase' }, reject_search_text: true)

      expect(result.outcome).to eq('unsupported')
      expect(result.reason).to eq('search_text_not_accepted')
      expect(result.to_h.to_json).not_to include('secret phrase')
    end

    it 'rejects a datetime that has no timezone' do
      result = resolve(source: 'public', kind: 'date', target: { at: '2024-01-01T00:00:00' }, context: public_context)

      expect(result.outcome).to eq('unsupported')
      expect(result.reason).to eq('timezone_required')
    end
  end

  describe 'public status membership' do
    let(:context) { public_context }

    it 'resolves a public row and keeps the id as a decimal string' do
      status = Fabricate(:status, account: author, visibility: :public)
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('resolved')
      expect(result.capability).to eq('supported')
      expect(result.anchor_id).to eq(status.id.to_s)
      expect(result.display_row_id).to eq(status.id.to_s)
      expect(result.to_h[:anchor_id]).to be_a(String)
    end

    it 'keeps a very large id as text' do
      snowflake = Mastodon::Snowflake.id_at(Time.utc(2024, 5, 1), with_random: false)
      status = Fabricate(:status, account: author, id: snowflake, created_at: Time.utc(2024, 5, 1), updated_at: Time.utc(2024, 5, 1))
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(status.id).to be > (2**53)
      expect(result.anchor_id).to eq(snowflake.to_s)
    end

    it 'says an unlisted post is not in the public source when the viewer can read it' do
      status = Fabricate(:status, account: author, visibility: :unlisted)
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_in_source')
      expect(result.anchor_id).to be_nil
    end

    it 'does not reveal a followers-only post to someone who does not follow' do
      status = Fabricate(:status, account: author, visibility: :private, text: 'followers-only-secret')
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_found')
      expect(result.to_h.to_json).not_to include('followers-only-secret')
    end

    it 'does not reveal a direct post' do
      status = Fabricate(:status, account: author, visibility: :direct, text: 'direct-secret-body')
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_found')
      expect(result.to_h.to_json).not_to include('direct-secret-body')
      expect(result.anchor_id).to be_nil
    end

    it 'says a followed private post is readable but not part of the public source' do
      viewer.follow!(author)
      status = Fabricate(:status, account: author, visibility: :private)
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_in_source')
    end

    it 'hides a muted account without calling the post missing' do
      viewer.mute!(author)
      status = Fabricate(:status, account: author, visibility: :public)
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_visible')
      expect(result.reason).to eq('viewer_filter')
    end

    it 'does not reveal a post whose author blocks the viewer' do
      author.block!(viewer)
      status = Fabricate(:status, account: author, visibility: :public, text: 'blocked-secret')
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_found')
      expect(result.to_h.to_json).not_to include('blocked-secret')
    end

    it 'treats a discarded post as not found' do
      status = Fabricate(:status, account: author, text: 'deleted-secret')
      status.discard
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_found')
      expect(result.to_h.to_json).not_to include('deleted-secret')
    end

    it 'follows a visibility change instead of the old public row' do
      status = Fabricate(:status, account: author, visibility: :public)
      status.update_columns(visibility: Status.visibilities[:private])
      result = resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('not_found')
    end

    it 'does not treat a boost wrapper as the public row' do
      original = Fabricate(:status, account: author, visibility: :public)
      boost = Fabricate(:status, account: viewer, reblog: original, text: '')
      result = resolve(source: 'public', kind: 'status', target: { id: boost.id.to_s }, context: context)

      expect(result.outcome).to eq('not_in_source')
      expect(resolve(source: 'public', kind: 'status', target: { id: original.id.to_s }, context: context).outcome).to eq('resolved')
    end

    it 'checks searchHit as source membership and does not echo a query' do
      status = Fabricate(:status, account: author, visibility: :public)
      result = resolve(source: 'public', kind: 'searchHit', target: { id: status.id.to_s }, context: context)

      expect(result.outcome).to eq('resolved')
      expect(result.limitations).to include('search_hit_is_membership_only')
    end
  end

  describe 'hashtag filters' do
    let(:news) { Fabricate(:tag, name: 'seeknews') }
    let(:extra) { Fabricate(:tag, name: 'seekextra') }
    let(:blocked) { Fabricate(:tag, name: 'seekblocked') }

    it 'honors any, all, and none instead of dropping them' do
      matched = Fabricate(:status, account: author, visibility: :public)
      excluded = Fabricate(:status, account: author, visibility: :public)
      matched.tags << news << extra
      excluded.tags << news << blocked

      context = public_context.merge(hashtag: 'seeknews', any: [], all: ['seekextra'], none: ['seekblocked'])

      expect(resolve(source: 'hashtag', kind: 'status', target: { id: matched.id.to_s }, context: context).outcome).to eq('resolved')
      expect(resolve(source: 'hashtag', kind: 'status', target: { id: excluded.id.to_s }, context: context).outcome).to eq('not_in_source')
    end
  end

  describe 'domain' do
    it 'resolves only the requested domain and does not invent a miss for an unknown domain' do
      remote = Fabricate(:account, domain: 'seek.example', username: 'remote')
      status = Fabricate(:status, account: remote, visibility: :public)
      other = Fabricate(:status, account: author, visibility: :public)

      expect(resolve(source: 'domain', kind: 'status', target: { id: status.id.to_s }, context: public_context.merge(domain: 'seek.example')).outcome).to eq('resolved')
      expect(resolve(source: 'domain', kind: 'status', target: { id: other.id.to_s }, context: public_context.merge(domain: 'seek.example')).outcome).to eq('not_in_source')

      missing = resolve(source: 'domain', kind: 'status', target: { id: status.id.to_s }, context: public_context.merge(domain: 'missing.example'))
      other_missing = resolve(source: 'domain', kind: 'date', target: { at: '2024-01-01T00:00:00Z' }, context: public_context.merge(domain: 'missing.example'))

      expect(missing.outcome).to eq('unavailable')
      expect(missing.reason).to eq('domain_unavailable')
      expect(other_missing.outcome).to eq('unavailable')
      expect(missing.anchor_id).to be_nil
    end
  end

  describe 'group' do
    let(:group) { Fabricate(:account, username: 'seekgroup', actor_type: 'Group') }

    it 'resolves a local public group post and hides a private one from outsiders' do
      public_status = Fabricate(:status, account: group, visibility: :public)
      private_status = Fabricate(:status, account: group, visibility: :private, text: 'group-private-secret')
      context = { id: group.id.to_s, only_media: false, without_media: false }

      expect(resolve(source: 'group', kind: 'status', target: { id: public_status.id.to_s }, context: context).outcome).to eq('resolved')

      hidden = resolve(source: 'group', kind: 'status', target: { id: private_status.id.to_s }, context: context)
      expect(hidden.outcome).to eq('not_found')
      expect(hidden.to_h.to_json).not_to include('group-private-secret')

      viewer.follow!(group)
      expect(resolve(source: 'group', kind: 'status', target: { id: private_status.id.to_s }, context: context).outcome).to eq('resolved')
    end

    it 'returns unsupported for a remote group without reading the target' do
      remote = Fabricate(:account, username: 'remotegroup', domain: 'groups.example', actor_type: 'Group', uri: 'https://groups.example/groups/remotegroup')
      status = Fabricate(:status, account: author, visibility: :public, text: 'not-a-group-post')
      context = { id: remote.id.to_s }

      real = resolve(source: 'group', kind: 'status', target: { id: status.id.to_s }, context: context)
      fake = resolve(source: 'group', kind: 'status', target: { id: '1' }, context: context)

      expect(real.outcome).to eq('unsupported')
      expect(real.reason).to eq('remote_group')
      expect(fake.to_h).to eq(real.to_h)
      expect(real.to_h.to_json).not_to include('not-a-group-post')
    end
  end

  describe 'personal' do
    it 'resolves the owner personal row and refuses account seek' do
      mine = Fabricate(:status, account: viewer, visibility: :personal)
      other = Fabricate(:status, account: author, visibility: :public)

      expect(resolve(source: 'personal', kind: 'status', target: { id: mine.id.to_s }).outcome).to eq('resolved')
      expect(resolve(source: 'personal', kind: 'status', target: { id: other.id.to_s }).outcome).to eq('not_in_source')
      expect(resolve(source: 'personal', kind: 'account', target: { account_id: viewer.id.to_s }).reason).to eq('personal_is_not_an_account_timeline')
    end
  end

  describe 'home and list redis window' do
    it 'resolves a retained home id and does not call a missing id absent' do
      inside = Fabricate(:status, account: author, visibility: :public)
      outside = Fabricate(:status, account: author, visibility: :public)
      place_in_home(viewer, inside)

      found = resolve(source: 'home', kind: 'status', target: { id: inside.id.to_s }, context: { visibilities: [] })
      missing = resolve(source: 'home', kind: 'status', target: { id: outside.id.to_s }, context: { visibilities: [] })

      expect(found.outcome).to eq('resolved')
      expect(found.capability).to eq('approximate')
      expect(found.limitations).to include('retention_2000')
      expect(missing.outcome).to eq('unavailable')
      expect(missing.reason).to eq('outside_retained_range')
      expect(missing.outcome).not_to eq('not_in_source')
    end

    it 'applies the limited visibility filter inside the retained set' do
      status = Fabricate(:status, account: author, visibility: :public)
      place_in_home(viewer, status)

      expect(resolve(source: 'limited', kind: 'status', target: { id: status.id.to_s }, context: { visibilities: ['public'] }).outcome).to eq('resolved')
      expect(resolve(source: 'limited', kind: 'status', target: { id: status.id.to_s }, context: { visibilities: ['private'] }).outcome).to eq('not_in_source')
    end

    it 'uses the list zset and does not promise an id outside it' do
      list = Fabricate(:list, account: viewer)
      status = Fabricate(:status, account: author, visibility: :public)
      redis.zadd(FeedManager.instance.key(:list, list.id), status.id, status.id)
      context = { id: list.id.to_s }

      expect(resolve(source: 'list', kind: 'status', target: { id: status.id.to_s }, context: context).outcome).to eq('resolved')
      other = Fabricate(:status, account: author, visibility: :public)
      expect(resolve(source: 'list', kind: 'status', target: { id: other.id.to_s }, context: context).reason).to eq('outside_retained_range')
    end

    it 'reports regeneration instead of a hard miss' do
      status = Fabricate(:status, account: author, visibility: :public)
      redis.set("account:#{viewer.id}:regeneration", '1')
      result = resolve(source: 'home', kind: 'status', target: { id: status.id.to_s }, context: { visibilities: [] })

      expect(result.outcome).to eq('unavailable')
      expect(result.reason).to eq('feed_regenerating')
    end

    it 'resolves the boost wrapper id that the home feed stores' do
      original = Fabricate(:status, account: author, visibility: :public)
      boost = Fabricate(:status, account: viewer, reblog: original, text: '')
      place_in_home(viewer, boost)

      expect(resolve(source: 'home', kind: 'status', target: { id: boost.id.to_s }, context: { visibilities: [] }).display_row_id).to eq(boost.id.to_s)
      expect(resolve(source: 'home', kind: 'searchHit', target: { id: original.id.to_s }, context: { visibilities: [] }).reason).to eq('outside_retained_range')
    end
  end

  describe 'date probe' do
    let(:context) { public_context }

    it 'uses created_at rather than the snowflake nearest to the timestamp' do
      target = Time.utc(2020, 6, 1)
      mismatch_id = Mastodon::Snowflake.id_at(target, with_random: false)
      match_id = Mastodon::Snowflake.id_at(target + 1.day, with_random: false)
      Fabricate(:status, account: author, id: mismatch_id, created_at: target + 30.days, updated_at: target + 30.days, text: 'id-near-time-far')
      match = Fabricate(:status, account: author, id: match_id, created_at: target, updated_at: target, text: 'time-match')

      result = resolve(source: 'public', kind: 'date', target: { at: target.iso8601 }, context: context)

      expect(result.outcome).to eq('resolved')
      expect(result.anchor_id).to eq(match.id.to_s)
      expect(result.precision).to eq('exact')
      expect(result.capability).to eq('approximate')
      expect(result.limitations).to include('id_order_not_created_at')
    end

    it 'distinguishes a zoned instant from a UTC calendar day' do
      jst = Time.iso8601('2024-01-01T00:00:00+09:00').utc
      utc = Time.utc(2024, 1, 1)
      jst_status = Fabricate(:status, account: author, id: Mastodon::Snowflake.id_at(jst, with_random: false), created_at: jst, updated_at: jst)
      utc_status = Fabricate(:status, account: author, id: Mastodon::Snowflake.id_at(utc, with_random: false), created_at: utc, updated_at: utc)

      zoned = resolve(source: 'public', kind: 'date', target: { at: '2024-01-01T00:00:00+09:00' }, context: context)
      day = resolve(source: 'public', kind: 'date', target: { at: '2024-01-01' }, context: context)

      expect(zoned.anchor_id).to eq(jst_status.id.to_s)
      expect(zoned.limitations).not_to include('utc_day_start')
      expect(day.anchor_id).to eq(utc_status.id.to_s)
      expect(day.limitations).to include('utc_day_start')
    end

    it 'returns nearest-before when nothing is exactly on the instant' do
      earlier = Time.utc(2021, 1, 1)
      later = Time.utc(2021, 1, 3)
      ask = Time.utc(2021, 1, 2)
      Fabricate(:status, account: author, id: Mastodon::Snowflake.id_at(earlier, with_random: false), created_at: earlier, updated_at: earlier)
      Fabricate(:status, account: author, id: Mastodon::Snowflake.id_at(later, with_random: false), created_at: later, updated_at: later)

      result = resolve(source: 'public', kind: 'date', target: { at: ask.iso8601 }, context: context, preference: 'before')

      expect(result.precision).to eq('nearest-before')
      expect(result.outcome).to eq('resolved')
    end
  end

  describe 'account probe' do
    it 'returns the newest probed public post and does not claim absence past the probe' do
      newest = Fabricate(:status, account: author, visibility: :public)
      result = resolve(source: 'public', kind: 'account', target: { account_id: author.id.to_s }, context: public_context)

      expect(result.outcome).to eq('resolved')
      expect(result.anchor_id).to eq(newest.id.to_s)
      expect(result.precision).to eq('newest-in-probe')
      expect(result.capability).to eq('approximate')

      20.times { Fabricate(:status, account: author, visibility: :unlisted) }
      exhausted = resolve(source: 'public', kind: 'account', target: { account_id: author.id.to_s }, context: public_context)

      expect(exhausted.outcome).to eq('unavailable')
      expect(exhausted.reason).to eq('account_probe_exhausted')
      expect(exhausted.outcome).not_to eq('not_in_source')
      expect(exhausted.outcome).not_to eq('not_found')
    end

    it 'finds a retained home row for the account without scanning the zset' do
      status = Fabricate(:status, account: author, visibility: :public)
      place_in_home(viewer, status)
      result = resolve(source: 'home', kind: 'account', target: { account_id: author.id.to_s }, context: { visibilities: [] })

      expect(result.outcome).to eq('resolved')
      expect(result.limitations).to include('account_probe_limit', 'retention_2000')
    end
  end

  describe 'query shape' do
    it 'checks public membership with an id limit and can use an index' do
      status = Fabricate(:status, account: author, visibility: :public)
      sqls = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
        sqls << payload[:sql] if payload[:sql].include?('statuses')
      end

      resolve(source: 'public', kind: 'status', target: { id: status.id.to_s }, context: public_context)

      membership = sqls.find { |sql| sql.include?('LIMIT') && sql.include?('statuses') }
      expect(membership).to be_present
      expect(membership).to match(/LIMIT/i)

      relation = Status.with_public_visibility.without_unreleased_pages.joins(:account).merge(Account.without_suspended.without_silenced).paginate_by_max_id(1, status.id + 1)
      Status.connection.execute('SET LOCAL enable_seqscan = off')
      plan = relation.explain
      expect(plan).to match(/Index Scan|Index Only Scan|Bitmap Index Scan/)
      expect(plan).to match(/Limit/i)
      expect(plan).not_to match(/Seq Scan on statuses/)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'probes an account through the account id index' do
      relation = Status.where(account_id: author.id, expired_at: nil).reorder(id: :desc).limit(TimelineSeek::Resolver::ACCOUNT_PROBE_LIMIT)
      Status.connection.execute('SET LOCAL enable_seqscan = off')
      plan = relation.explain

      expect(plan).to match(/Index Scan|Index Only Scan|Bitmap Index Scan/)
      expect(plan).to match(/Limit/i)
      expect(plan).not_to match(/Seq Scan on statuses/)
    end
  end
end
