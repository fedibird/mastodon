# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFilter, type: :model do # rubocop:disable Metrics/BlockLength
  def mute(account, name, expires_in: nil)
    HashtagMutes::UpsertService.new.call(account, name: name, expires_in: expires_in)
  end

  def apply(account, status)
    cached = described_class.cached_filters_for(account.id)
    described_class.apply_cached_filters(cached, status)
  end

  def tag_with(status, name)
    status.tags << Tag.find_or_create_by_names(name).first
    status
  end

  def sql_queries
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == 'SCHEMA' || payload[:cached]
      next if sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      queries << sql
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  let(:viewer) { Fabricate(:account) }
  let(:author) { Fabricate(:account) }

  it 'matches the exact tag and not a longer tag, plain text, or a URL' do
    mute(viewer, '番組')
    exact = tag_with(Fabricate(:status, account: author, text: 'hello'), '番組')
    longer = tag_with(Fabricate(:status, account: author, text: 'hello'), '番組実況')
    plain = Fabricate(:status, account: author, text: '番組 https://example.com/tags/番組')
    ascii = tag_with(Fabricate(:status, account: author, text: 'hello'), 'ABCD')
    short = tag_with(Fabricate(:status, account: author, text: 'hello'), 'ABC')

    expect(apply(viewer, exact).map(&:tag_matches)).to eq [['番組']]
    expect(apply(viewer, longer)).to be_empty
    expect(apply(viewer, plain)).to be_empty

    mute(viewer, 'ABC')
    Rails.cache.clear
    expect(apply(viewer, ascii)).to be_empty
    expect(apply(viewer, short).map(&:tag_matches).flatten).to include('abc')
  end

  it 'folds case and a fullwidth hash into the stored tag identity' do
    filter = mute(viewer, '＃AbC')

    expect(filter.filter_tags.pluck(:name)).to eq ['abc']
    expect(filter.title).to eq '#AbC'
    expect(apply(viewer, tag_with(Fabricate(:status, account: author, text: 'hello'), 'aBc')).map { |result| result.filter.id }).to eq [filter.id]
  end

  it 'matches a boost of a tagged post and not a quote that does not carry the tag' do
    mute(viewer, '番組')
    tag = Tag.find_or_create_by_names('番組').first
    original = tag_with(Fabricate(:status, account: author, text: 'live'), '番組')
    boost = Fabricate(:status, account: author, reblog: original)
    quoted = tag_with(Fabricate(:status, account: author, text: 'source'), '番組')
    quoting = Fabricate(:status, account: author, text: 'see this', quote_id: quoted.id)
    Status.preload_cacheable_associations([boost, quoting])

    expect(quoting.tags).to be_empty
    expect(quoted.tags).to include(tag)
    expect(apply(viewer, boost).map { |result| result.filter.phrase }).to eq ['#番組']
    expect(apply(viewer, quoting)).to be_empty

    tag_with(quoting, '番組')
    expect(apply(viewer, quoting.reload)).not_to be_empty
  end

  it 'does not query tags again when the timeline preload is present' do
    mute(viewer, '番組')
    statuses = Array.new(3) { tag_with(Fabricate(:status, account: author, text: 'hello'), '番組') }
    Status.preload_cacheable_associations(statuses)
    cached = described_class.cached_filters_for(viewer.id)

    queries = sql_queries do
      statuses.each do |status|
        expect(described_class.apply_cached_filters(cached, status)).not_to be_empty
      end
    end

    expect(queries.grep(/statuses_tags|FROM "tags"/i)).to be_empty
  end

  it 'normalizes tags once when many tag rules are checked' do
    tag_sql = /statuses_tags|FROM "tags"/i
    one_status = tag_with(Fabricate(:status, account: author, text: 'hello'), '番組')
    many_status = tag_with(Fabricate(:status, account: author, text: 'hello'), '番組')
    preloaded = tag_with(Fabricate(:status, account: author, text: 'hello'), '番組')
    Status.preload_cacheable_associations([preloaded])

    mute(viewer, '番組')
    one_cache = described_class.cached_filters_for(viewer.id)
    Rails.cache.clear
    20.times { |index| mute(viewer, "tag#{index}") }
    many_cache = described_class.cached_filters_for(viewer.id)

    one_queries = sql_queries { described_class.apply_cached_filters(one_cache, one_status) }
    many_queries = sql_queries { described_class.apply_cached_filters(many_cache, many_status) }
    preloaded_queries = sql_queries { described_class.apply_cached_filters(many_cache, preloaded) }

    expect(many_queries.grep(tag_sql).size).to eq(one_queries.grep(tag_sql).size)
    expect(preloaded_queries.grep(tag_sql)).to be_empty
    expect(described_class.apply_cached_filters(many_cache, preloaded).map { |result| result.filter.phrase }).to eq ['#番組']
  end

  it 'keeps one rule when the duration is extended or cleared, and leaves keyword filters alone' do
    keyword = Fabricate(:custom_filter, account: viewer, phrase: '番組', context: %w(home notifications public thread account))
    Fabricate(:custom_filter_keyword, custom_filter: keyword, keyword: '番組', whole_word: false)
    timed = mute(viewer, '番組', expires_in: 300)
    extended = mute(viewer, '番組', expires_in: 3.hours.to_i)
    cleared = mute(viewer, '番組', expires_in: 0)

    expect(extended.id).to eq timed.id
    expect(cleared.id).to eq timed.id
    expect(cleared.reload.expires_at).to be_nil
    expect(described_class.where(account: viewer).count).to eq 2
    expect(keyword.reload.phrase).to eq '番組'
    expect(keyword.expires_at).to be_nil
    expect(keyword.keywords.pluck(:keyword)).to eq ['番組']

    body = Fabricate(:status, account: author, text: '番組だけ本文')
    tagged = tag_with(Fabricate(:status, account: author, text: '番組だけ本文'), '番組')
    Rails.cache.clear

    expect(apply(viewer, body).map { |result| result.filter.id }).to eq [keyword.id]
    expect(apply(viewer, tagged).map { |result| result.filter.id }).to contain_exactly(keyword.id, timed.id)
  end

  it 'treats the exact expires_at as already expired and a moment earlier as active' do
    filter = mute(viewer, '番組', expires_in: 5.minutes.to_i)
    status = tag_with(Fabricate(:status, account: author, text: 'hello'), '番組')
    # travel_to in Rails 6.1 drops microseconds, so the boundary itself is a whole second.
    boundary = 5.minutes.from_now.change(usec: 0)
    filter.update!(expires_at: boundary)

    expect(described_class.still_active?(filter, boundary - 0.000001)).to be true
    expect(described_class.still_active?(filter, boundary)).to be false

    travel_to(boundary - 1.second) do
      Rails.cache.clear
      expect(apply(viewer, status)).not_to be_empty
    end

    travel_to(boundary) do
      Rails.cache.clear
      expect(described_class.unexpired.where(id: filter.id)).to be_empty
      expect(apply(viewer, status)).to be_empty
      expect(described_class.where(id: filter.id)).to exist
    end
  end

  it 'turns a warn rule back into hide without moving its context or keyword' do
    filter = mute(viewer, '番組', expires_in: 2.hours.to_i)
    filter.update!(action: :warn, context: %w(home))
    Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: '別件')
    expiry = filter.expires_at

    kept = HashtagMutes::UpsertService.new.call(viewer, name: '番組', expires_in: 5.minutes.to_i, preserve_expiry: true)

    expect(kept.id).to eq filter.id
    expect(kept.reload.action).to eq 'hide'
    expect(kept.context).to eq %w(home)
    expect(kept.expires_at).to be_within(1.second).of(expiry)
    expect(kept.keywords.pluck(:keyword)).to eq ['別件']

    removed = HashtagMutes::RemoveService.new.call(kept)
    expect(removed.id).to eq filter.id
    expect(removed.filter_tags).to be_empty
    expect(removed.keywords.pluck(:keyword)).to eq ['別件']
  end

  it 'rejects an empty name, an invalid character, and a duration outside the list' do
    expect { mute(viewer, '', expires_in: nil) }.to raise_error(Mastodon::ValidationError)
    expect { mute(viewer, 'bad tag', expires_in: nil) }.to raise_error(Mastodon::ValidationError)
    expect { mute(viewer, '番組', expires_in: 1) }.to raise_error(Mastodon::ValidationError)
    expect { mute(viewer, '番組', expires_in: '999999999999') }.to raise_error(Mastodon::ValidationError)
    expect { mute(viewer, 'a' * 300, expires_in: nil) }.to raise_error(Mastodon::ValidationError)

    expect(described_class.where(account: viewer)).to be_empty
  end
end
