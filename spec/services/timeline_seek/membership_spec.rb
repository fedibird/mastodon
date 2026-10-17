# frozen_string_literal: true

require 'rails_helper'

describe TimelineSeek::Membership do
  subject { described_class.new(viewer, user: viewer.user) }

  let(:viewer) { Fabricate(:user).account }
  let(:author) { Fabricate(:user).account }

  def classify(source:, ids:, context: {}, version: 1, **extra)
    subject.call({ version: version, source: source, context: context, ids: ids }.merge(extra))
  end

  def public_context
    { only_media: false, without_media: false, without_bot: false }
  end

  def outcomes(result)
    result.to_h[:results].map { |row| [row[:id], row[:outcome]] }.to_h
  end

  def place_in_home(account, status)
    redis.zadd(FeedManager.instance.key(:home, account.id), status.id, status.id)
  end

  def capture_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
      sqls << payload[:sql]
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  describe 'input bounds' do
    it 'rejects search text without echoing it or classifying ids' do
      status = Fabricate(:status, account: author, visibility: :public, text: 'body-should-stay-hidden')
      result = classify(source: 'public', ids: [status.id.to_s], context: public_context.merge(q: 'secret phrase'))

      expect(result.outcome).to eq('unsupported')
      expect(result.reason).to eq('search_text_not_accepted')
      expect(result.to_h).not_to have_key(:results)
      expect(result.to_h).not_to have_key(:members)
      expect(result.to_h.to_json).not_to include('secret phrase')
      expect(result.to_h.to_json).not_to include('body-should-stay-hidden')
    end

    it 'rejects a top-level query and a closed source without upgrading it' do
      text = subject.call(version: 1, source: 'public', ids: ['1'], q: 'hidden query')
      closed = classify(source: 'mix', ids: ['1'])

      expect(text.reason).to eq('search_text_not_accepted')
      expect(text.to_h.to_json).not_to include('hidden query')
      expect(closed.outcome).to eq('unsupported')
      expect(closed.reason).to eq('source_has_no_windowed_history')
      expect(closed.to_h).not_to have_key(:results)
    end

    it 'rejects the whole call when more than 50 ids are sent' do
      status = Fabricate(:status, account: author, visibility: :public, text: 'over-limit-secret')
      ids = [status.id.to_s] + Array.new(50) { |index| (index + 1).to_s }
      sqls = capture_sql { @result = classify(source: 'public', ids: ids, context: public_context) }

      expect(ids.size).to eq(51)
      expect(@result.reason).to eq('too_many_ids')
      expect(@result.to_h).not_to have_key(:results)
      expect(@result.to_h[:limits][:ids]).to eq(50)
      expect(@result.to_h.to_json).not_to include('over-limit-secret')
      expect(sqls.join("\n")).not_to include(status.id.to_s)
    end

    it 'drops duplicate ids and does not echo an invalid token' do
      status = Fabricate(:status, account: author, visibility: :public)
      result = classify(source: 'public', ids: [status.id.to_s, "0#{status.id}", 'nope'], context: public_context)

      expect(TimelineSeek::StatusId.parse("0#{status.id}")).to eq(status.id)
      expect(result.outcome).to eq('complete')
      expect(result.limitations).to include('duplicate_ids')
      expect(result.to_h[:checked]).to eq(2)
      expect(result.to_h[:members]).to eq([status.id.to_s])
      expect(result.to_h.to_json).not_to include('nope')
      expect(result.to_h[:results].map { |row| row[:outcome] }).to eq(%w(member invalid))
    end

    it 'rejects a missing id list and a bad version before opening a source' do
      expect(classify(source: 'list', ids: [], context: { id: '1' }).reason).to eq('missing_ids')
      expect(classify(source: 'public', ids: ['1'], version: 2).reason).to eq('version')
      expect(classify(source: 'public', ids: '1').reason).to eq('invalid_ids')
    end
  end

  describe 'public membership' do
    let(:context) { public_context }

    it 'returns only confirmed members, newest id first, as decimal strings' do
      older = Fabricate(:status, account: author, visibility: :public)
      newer = Fabricate(:status, account: author, visibility: :public)
      snowflake = Mastodon::Snowflake.id_at(Time.utc(2024, 5, 1), with_random: false)
      wide = Fabricate(:status, account: author, id: snowflake, created_at: Time.utc(2024, 5, 1), updated_at: Time.utc(2024, 5, 1))
      unlisted = Fabricate(:status, account: author, visibility: :unlisted)

      result = classify(source: 'public', ids: [older.id.to_s, unlisted.id.to_s, wide.id.to_s, newer.id.to_s], context: context)

      expect(wide.id).to be > (2**53)
      expect(newer.id).to be > older.id
      expect(older.id).to be > wide.id
      expect(result.outcome).to eq('complete')
      expect(result.capability).to eq('supported')
      expect(result.to_h[:members]).to eq([newer.id.to_s, older.id.to_s, wide.id.to_s])
      expect(result.to_h[:results].find { |row| row[:id] == unlisted.id.to_s }[:outcome]).to eq('not_in_source')
      expect(result.to_h.to_json).to include(%("#{wide.id}"))
    end

    it 'hides followers-only, direct, blocked, deleted, and expired rows without their text' do
      direct = Fabricate(:status, account: author, visibility: :direct, text: 'direct-secret-body')
      private_status = Fabricate(:status, account: author, visibility: :private, text: 'followers-only-secret')
      blocked = Fabricate(:status, account: author, visibility: :public, text: 'blocked-secret')
      author.block!(viewer)
      deleted = Fabricate(:status, account: author, text: 'deleted-secret')
      deleted.discard
      expired = Fabricate(:status, account: author, text: 'expired-secret')
      expired.update_columns(expired_at: 1.hour.ago)
      visible = Fabricate(:status, account: Fabricate(:account), visibility: :public)

      result = classify(
        source: 'public',
        ids: [direct.id.to_s, private_status.id.to_s, blocked.id.to_s, deleted.id.to_s, expired.id.to_s, visible.id.to_s],
        context: context
      )

      expect(outcomes(result)).to include(
        direct.id.to_s => 'not_found',
        private_status.id.to_s => 'not_found',
        blocked.id.to_s => 'not_found',
        deleted.id.to_s => 'not_found',
        expired.id.to_s => 'not_found',
        visible.id.to_s => 'member'
      )
      body = result.to_h.to_json
      expect(body).not_to include('direct-secret-body')
      expect(body).not_to include('followers-only-secret')
      expect(body).not_to include('blocked-secret')
      expect(body).not_to include('deleted-secret')
      expect(body).not_to include('expired-secret')
      expect(body).not_to include(author.username)
    end

    it 'says a followed private post is readable but not part of the public source' do
      viewer.follow!(author)
      status = Fabricate(:status, account: author, visibility: :private)
      result = classify(source: 'public', ids: [status.id.to_s], context: context)

      expect(outcomes(result)).to eq(status.id.to_s => 'not_in_source')
    end

    it 'reports a mute or a language filter as not visible, and keeps the row out of members' do
      muted = Fabricate(:status, account: author, visibility: :public, text: 'muted-body')
      viewer.mute!(author)
      other = Fabricate(:account)
      foreign = Fabricate(:status, account: other, visibility: :public, language: 'en', text: 'english-body')
      viewer.user.update!(chosen_languages: ['ja'])

      result = classify(source: 'public', ids: [muted.id.to_s, foreign.id.to_s], context: context)

      expect(result.to_h[:members]).to eq([])
      expect(result.to_h[:results]).to include(include(id: muted.id.to_s, outcome: 'not_visible', reason: 'viewer_filter'))
      expect(result.to_h[:results]).to include(include(id: foreign.id.to_s, outcome: 'not_visible', reason: 'viewer_filter'))
      expect(result.to_h.to_json).not_to include('muted-body')
      expect(result.to_h.to_json).not_to include('english-body')
    end

    it 'applies a hide filter and does not return the keyword or the body' do
      matched = Fabricate(:status, account: author, visibility: :public, text: 'alpha secret-keyword beta')
      kept = Fabricate(:status, account: author, visibility: :public, text: 'ordinary post')
      warned = Fabricate(:status, account: author, visibility: :public, text: 'warn-keyword stays')
      filter = Fabricate(:custom_filter, account: viewer, phrase: 'secret-keyword', context: %w(public), action: :hide)
      Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: 'secret-keyword', whole_word: false)
      warn = Fabricate(:custom_filter, account: viewer, phrase: 'warn-keyword', context: %w(public), action: :warn)
      Fabricate(:custom_filter_keyword, custom_filter: warn, keyword: 'warn-keyword', whole_word: false)
      hidden = Fabricate(:custom_filter, account: viewer, phrase: 'status-hide', context: %w(public), action: :hide)
      Fabricate(:custom_filter_status, custom_filter: hidden, status: kept)

      result = classify(source: 'public', ids: [matched.id.to_s, kept.id.to_s, warned.id.to_s], context: context)

      expect(outcomes(result)).to eq(matched.id.to_s => 'not_visible', kept.id.to_s => 'not_visible', warned.id.to_s => 'member')
      expect(result.to_h[:members]).to eq([warned.id.to_s])
      body = result.to_h.to_json
      expect(body).not_to include('secret-keyword')
      expect(body).not_to include('warn-keyword')
      expect(body).not_to include('alpha secret-keyword beta')
      expect(body).not_to include('ordinary post')
    end

    it 'does not let a home-only filter hide a public hit' do
      status = Fabricate(:status, account: author, visibility: :public, text: 'public-column-body')
      filter = Fabricate(:custom_filter, account: viewer, phrase: 'public-column-body', context: %w(home), action: :hide)
      Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: 'public-column-body', whole_word: false)

      result = classify(source: 'public', ids: [status.id.to_s], context: context)

      expect(result.to_h[:members]).to eq([status.id.to_s])
      expect(result.to_h.to_json).not_to include('public-column-body')
    end

    it 'does not treat a boost wrapper as the public row' do
      original = Fabricate(:status, account: author, visibility: :public)
      boost = Fabricate(:status, account: viewer, reblog: original, text: '')
      result = classify(source: 'public', ids: [boost.id.to_s, original.id.to_s], context: context)

      expect(outcomes(result)).to eq(boost.id.to_s => 'not_in_source', original.id.to_s => 'member')
    end

    it 'classifies a batch where most hits belong to another visibility in one pass' do
      hit = Fabricate(:status, account: author, visibility: :public, text: 'the-one-hit')
      others = Array.new(49) { Fabricate(:status, account: author, visibility: :unlisted) }
      ids = others.map { |status| status.id.to_s } + [hit.id.to_s]
      sqls = capture_sql { @result = classify(source: 'public', ids: ids, context: context) }
      status_sql = sqls.select { |sql| sql.include?('statuses') && !sql.include?('custom_filter') }

      expect(@result.outcome).to eq('complete')
      expect(@result.to_h[:members]).to eq([hit.id.to_s])
      expect(@result.to_h[:results].count { |row| row[:outcome] == 'not_in_source' }).to eq(49)
      expect(@result.to_h.to_json).not_to include('the-one-hit')
      expect(status_sql.count { |sql| sql.match?(/LIMIT (?:1|\$1)\b/) }).to eq(0)
      expect(status_sql.count { |sql| sql.match?(/\bIN \(|ANY\s*\(/i) }).to be_between(1, 3)
    end

    it 'matches single-id seek outcomes for the same scope' do
      muted_author = Fabricate(:account)
      viewer.mute!(muted_author)
      samples = [
        Fabricate(:status, account: author, visibility: :public),
        Fabricate(:status, account: author, visibility: :unlisted),
        Fabricate(:status, account: muted_author, visibility: :public),
        Fabricate(:status, account: author, visibility: :direct, text: 'seek-direct-secret'),
      ]
      batch = classify(source: 'public', ids: samples.map { |status| status.id.to_s }, context: context)
      resolver = TimelineSeek::Resolver.new(viewer, user: viewer.user)

      samples.each do |status|
        seek = resolver.call(version: 1, source: 'public', kind: 'searchHit', preference: 'nearest', context: context, seek_target: { id: status.id.to_s })
        row = batch.to_h[:results].find { |item| item[:id] == status.id.to_s }
        expected = { 'resolved' => 'member', 'not_in_source' => 'not_in_source', 'not_visible' => 'not_visible', 'not_found' => 'not_found' }.fetch(seek.outcome)
        expect(row[:outcome]).to eq(expected), "id #{status.id} seek #{seek.outcome}"
      end
      expect(batch.to_h.to_json).not_to include('seek-direct-secret')
    end
  end

  describe 'source filters' do
    it 'honors hashtag any, all, and none for the whole set' do
      news = Fabricate(:tag, name: 'seeknews')
      extra = Fabricate(:tag, name: 'seekextra')
      blocked = Fabricate(:tag, name: 'seekblocked')
      matched = Fabricate(:status, account: author, visibility: :public)
      excluded = Fabricate(:status, account: author, visibility: :public)
      matched.tags << news << extra
      excluded.tags << news << blocked
      context = public_context.merge(hashtag: 'seeknews', any: [], all: ['seekextra'], none: ['seekblocked'])

      result = classify(source: 'hashtag', ids: [matched.id.to_s, excluded.id.to_s], context: context)

      expect(outcomes(result)).to eq(matched.id.to_s => 'member', excluded.id.to_s => 'not_in_source')
    end

    it 'keeps an unknown domain unavailable for every id' do
      remote = Fabricate(:account, domain: 'seek.example', username: 'remote')
      status = Fabricate(:status, account: remote, visibility: :public, text: 'domain-body')
      missing = classify(source: 'domain', ids: [status.id.to_s, '1'], context: public_context.merge(domain: 'missing.example'))
      found = classify(source: 'domain', ids: [status.id.to_s], context: public_context.merge(domain: 'seek.example'))

      expect(missing.outcome).to eq('unavailable')
      expect(missing.reason).to eq('domain_unavailable')
      expect(missing.to_h).not_to have_key(:results)
      expect(missing.to_h).to eq(classify(source: 'domain', ids: ['1'], context: public_context.merge(domain: 'missing.example')).to_h)
      expect(missing.to_h.to_json).not_to include('domain-body')
      expect(found.to_h[:members]).to eq([status.id.to_s])
    end

    it 'resolves a local group post and does not reveal a private or remote group' do
      group = Fabricate(:account, username: 'seekgroup', actor_type: 'Group')
      public_status = Fabricate(:status, account: group, visibility: :public)
      private_status = Fabricate(:status, account: group, visibility: :private, text: 'group-private-secret')
      context = { id: group.id.to_s, only_media: false, without_media: false }

      hidden = classify(source: 'group', ids: [public_status.id.to_s, private_status.id.to_s], context: context)
      expect(outcomes(hidden)).to eq(public_status.id.to_s => 'member', private_status.id.to_s => 'not_found')
      expect(hidden.to_h.to_json).not_to include('group-private-secret')

      viewer.follow!(group)
      visible = classify(source: 'group', ids: [private_status.id.to_s], context: context)
      expect(visible.to_h[:members]).to eq([private_status.id.to_s])

      remote = Fabricate(:account, username: 'remotegroup', domain: 'groups.example', actor_type: 'Group', uri: 'https://groups.example/groups/remotegroup')
      secret = Fabricate(:status, account: author, visibility: :public, text: 'not-a-group-post')
      real = classify(source: 'group', ids: [secret.id.to_s], context: { id: remote.id.to_s })
      fake = classify(source: 'group', ids: ['1'], context: { id: remote.id.to_s })

      expect(real.to_h).to eq(fake.to_h)
      expect(real.reason).to eq('remote_group')
      expect(real.to_h.to_json).not_to include('not-a-group-post')
    end

    it 'does not read another account list or treat a user as a group' do
      foreign = Fabricate(:list, account: author)
      status = Fabricate(:status, account: author, text: 'foreign-list-secret')

      expect { classify(source: 'list', ids: [status.id.to_s], context: { id: foreign.id.to_s }) }.to raise_error(ActiveRecord::RecordNotFound)
      expect { classify(source: 'group', ids: [status.id.to_s], context: { id: author.id.to_s }) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'resolves the owner personal row, including an expired one, and not someone else' do
      mine = Fabricate(:status, account: viewer, visibility: :personal, text: 'my-personal')
      mine.update_columns(expired_at: 1.hour.ago)
      other = Fabricate(:status, account: author, visibility: :public, text: 'other-public')
      result = classify(source: 'personal', ids: [mine.id.to_s, other.id.to_s])

      expect(outcomes(result)).to eq(mine.id.to_s => 'member', other.id.to_s => 'not_in_source')
      expect(result.to_h.to_json).not_to include('my-personal')
      expect(result.to_h.to_json).not_to include('other-public')
    end

    it 'drops service actors and posts without media when those source flags are set' do
      person = Fabricate(:account, username: 'seekperson', actor_type: 'Person')
      bot = Fabricate(:account, username: 'seekbot', actor_type: 'Service')
      bot_status = Fabricate(:status, account: bot, visibility: :public)
      plain = Fabricate(:status, account: person, visibility: :public)
      with_media = Fabricate(:status, account: author, visibility: :public)
      Fabricate(:media_attachment, account: author, status: with_media)

      bots = classify(source: 'public', ids: [bot_status.id.to_s, plain.id.to_s], context: public_context.merge(without_bot: true))
      media = classify(source: 'public', ids: [with_media.id.to_s, plain.id.to_s], context: public_context.merge(only_media: true))

      expect(outcomes(bots)).to eq(bot_status.id.to_s => 'not_in_source', plain.id.to_s => 'member')
      expect(outcomes(media)).to eq(with_media.id.to_s => 'member', plain.id.to_s => 'not_in_source')
    end
  end

  describe 'redis window' do
    it 'confirms retained home ids and leaves the rest unknown' do
      inside = Fabricate(:status, account: author, visibility: :public, text: 'inside-home')
      outside = Fabricate(:status, account: author, visibility: :public, text: 'outside-home')
      secret = Fabricate(:status, account: author, visibility: :direct, text: 'home-direct-secret')
      place_in_home(viewer, inside)
      place_in_home(Fabricate(:account), outside)

      round_trips = { zmscore: 0, pipelined: 0 }
      allow(redis).to receive(:zmscore).and_wrap_original do |method, *args|
        round_trips[:zmscore] += 1
        method.call(*args)
      end
      allow(redis).to receive(:pipelined).and_wrap_original do |method, *args, &block|
        round_trips[:pipelined] += 1
        method.call(*args, &block)
      end

      result = classify(source: 'home', ids: [inside.id.to_s, outside.id.to_s, secret.id.to_s], context: { visibilities: [], account_id: author.id.to_s })

      expect(result.outcome).to eq('partial')
      expect(result.capability).to eq('approximate')
      expect(result.limitations).to include('retention_2000')
      expect(result.to_h[:members]).to eq([inside.id.to_s])
      expect(result.to_h[:results]).to include(include(id: outside.id.to_s, outcome: 'unknown', reason: 'outside_retained_range'))
      expect(result.to_h[:results]).to include(include(id: secret.id.to_s, outcome: 'not_found'))
      expect(result.to_h[:results].map { |row| row[:outcome] }).not_to include('not_in_source')
      expect(result.to_h.to_json).not_to include('outside-home')
      expect(result.to_h.to_json).not_to include('home-direct-secret')
      expect(round_trips[:zmscore] + round_trips[:pipelined]).to eq(1)
    end

    it 'applies the limited visibility filter inside the retained set' do
      status = Fabricate(:status, account: author, visibility: :public)
      place_in_home(viewer, status)

      shown = classify(source: 'limited', ids: [status.id.to_s], context: { visibilities: ['public'] })
      hidden = classify(source: 'limited', ids: [status.id.to_s], context: { visibilities: ['private'] })

      expect(shown.to_h[:members]).to eq([status.id.to_s])
      expect(hidden.to_h[:results].first).to include(outcome: 'not_in_source', reason: 'source_filter')
    end

    it 'uses the list zset and does not promise an id outside it' do
      list = Fabricate(:list, account: viewer)
      inside = Fabricate(:status, account: author, visibility: :public)
      outside = Fabricate(:status, account: author, visibility: :public)
      redis.zadd(FeedManager.instance.key(:list, list.id), inside.id, inside.id)

      result = classify(source: 'list', ids: [inside.id.to_s, outside.id.to_s], context: { id: list.id.to_s })

      expect(result.outcome).to eq('partial')
      expect(result.to_h[:members]).to eq([inside.id.to_s])
      expect(result.to_h[:results]).to include(include(id: outside.id.to_s, outcome: 'unknown', reason: 'outside_retained_range'))
    end

    it 'reports regeneration instead of a hard miss' do
      status = Fabricate(:status, account: author, visibility: :public)
      redis.set("account:#{viewer.id}:regeneration", '1')
      result = classify(source: 'home', ids: [status.id.to_s], context: { visibilities: [] })

      expect(result.outcome).to eq('partial')
      expect(result.limitations).to include('feed_regenerating')
      expect(result.to_h[:results].first).to include(outcome: 'unknown', reason: 'feed_regenerating')
    end

    it 'resolves the boost wrapper the home feed stores and not the original' do
      original = Fabricate(:status, account: author, visibility: :public)
      boost = Fabricate(:status, account: viewer, reblog: original, text: '')
      place_in_home(viewer, boost)
      result = classify(source: 'home', ids: [boost.id.to_s, original.id.to_s], context: { visibilities: [] })

      expect(result.to_h[:members]).to eq([boost.id.to_s])
      expect(result.to_h[:results]).to include(include(id: original.id.to_s, outcome: 'unknown', reason: 'outside_retained_range'))
    end
  end

  describe 'query shape' do
    it 'checks a public id set with one bounded query and can use an index' do
      status = Fabricate(:status, account: author, visibility: :public)
      others = Array.new(7) { Fabricate(:status, account: author, visibility: :public) }
      ids = ([status] + others).map { |item| item.id.to_s }

      described_class.new(viewer, user: viewer.user).call(version: 1, source: 'public', context: public_context, ids: [status.id.to_s])
      one = capture_sql { described_class.new(viewer, user: viewer.user).call(version: 1, source: 'public', context: public_context, ids: [status.id.to_s]) }
      many = capture_sql { described_class.new(viewer, user: viewer.user).call(version: 1, source: 'public', context: public_context, ids: ids) }

      expect(many.size).to eq(one.size)
      expect(many.count { |sql| sql.match?(/LIMIT (?:1|\$1)\b/) }).to eq(0)
      expect(many.join("\n")).to match(/LIMIT/i)

      relation = PublicFeed.new(viewer, public_context.merge(application: nil)).relation.where(statuses: { id: ids.map(&:to_i) }).unscope(:order).distinct.limit(described_class::MAX_IDS)
      Status.connection.execute('SET LOCAL enable_seqscan = off')
      plan = relation.explain
      expect(plan).to match(/Index Scan|Index Only Scan|Bitmap Index Scan/)
      expect(plan).to match(/Limit/i)
      expect(plan).not_to match(/Seq Scan on statuses\b/)
    end

    it 'explains hashtag, personal, group, and home selectable scopes without a status seq scan' do
      tag = Fabricate(:tag, name: 'seekplan')
      status = Fabricate(:status, account: author, visibility: :public)
      status.tags << tag
      group = Fabricate(:account, username: 'plangroup', actor_type: 'Group')
      group_status = Fabricate(:status, account: group, visibility: :public)
      personal = Fabricate(:status, account: viewer, visibility: :personal)
      ids = [status.id, group_status.id, personal.id]

      plans = {
        hashtag: TagFeed.new(tag, viewer, public_context).relation.where(statuses: { id: ids }).unscope(:order).distinct.limit(50),
        personal: PersonalFeed.new(viewer, only_media: false, without_media: false).relation.where(statuses: { id: ids }).unscope(:order).distinct.limit(50),
        group: GroupFeed.new(group, viewer, only_media: false, without_media: false).relation.where(statuses: { id: ids }).unscope(:order).distinct.limit(50),
        home: Status.where(id: ids).without_unreleased_pages.joins(:account).merge(Account.without_suspended).limit(50),
      }

      Status.connection.execute('SET LOCAL enable_seqscan = off')
      plans.each do |name, relation|
        plan = relation.explain
        expect(plan).to match(/Index Scan|Index Only Scan|Bitmap Index Scan/), name.to_s
        expect(plan).not_to match(/Seq Scan on statuses\b/), "#{name}\n#{plan}"
      end
    end

    it 'uses the same public scope as a point lookup' do
      hit = Fabricate(:status, account: author, visibility: :public)
      miss = Fabricate(:status, account: author, visibility: :unlisted)
      reader = TimelineSeek::Resolver.new(viewer, user: viewer.user).open_reader('public', public_context)

      expect(reader.scope_ids([hit.id, miss.id], limit: 50)).to contain_exactly(hit.id)
      expect(reader.contains?(hit.id)).to be true
      expect(reader.contains?(miss.id)).to be false
    end
  end
end
