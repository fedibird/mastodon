# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountStatusesTaggedQuery do
  def cte_and_outer(sql)
    head, tail = sql.split(') SELECT statuses.*', 2)
    [head.to_s, tail.to_s]
  end

  def legacy_rows(account:, viewer:, tag:, limit:, page: {}, exclude_replies: false, exclude_reblogs: false, hide_personal: false)
    scope = account.permitted_statuses(viewer)
    scope = scope.merge(Status.include_expired.without_replies) if exclude_replies
    scope = scope.merge(Status.include_expired.without_reblogs) if exclude_reblogs
    scope = scope.merge(tag ? Status.include_expired.tagged_with(tag.id) : Status.none)
    scope = scope.merge(Status.include_expired.without_personal_visibility) if hide_personal
    scope.to_a_paginated_by_id(limit, page).map { |status| [status.id, status.text] }
  end

  def query_rows(account:, viewer:, tag:, limit:, page: {}, exclude_replies: false, exclude_reblogs: false, hide_personal: false)
    candidate = account.permitted_statuses(viewer)
    candidate = candidate.merge(Status.include_expired.without_personal_visibility) if hide_personal

    described_class.new(
      candidate_scope: candidate,
      tag_id: tag.id,
      limit: limit,
      page: page,
      filters: { exclude_replies: exclude_replies, exclude_reblogs: exclude_reblogs }
    ).records.map { |status| [status.id, status.text] }
  end

  describe 'CTE materialization keyword' do
    it 'marks the CTE MATERIALIZED on PostgreSQL 12 and newer' do
      expect(described_class.materialization_keyword(120_000)).to eq 'MATERIALIZED '
      expect(described_class.materialization_keyword(160_015)).to eq 'MATERIALIZED '
    end

    it 'omits the keyword on PostgreSQL 10 and 11' do
      expect(described_class.materialization_keyword(100_000)).to eq ''
      expect(described_class.materialization_keyword(110_000)).to eq ''
      expect(described_class.materialization_keyword(119_999)).to eq ''
    end
  end

  describe 'SQL shape' do
    let(:account) { Account.new(id: 1) }
    let(:candidate_scope) { account.statuses.permitted_for(account, nil) }

    def build_sql(**options)
      described_class.new(**{
        candidate_scope: candidate_scope,
        tag_id: 2_589_383,
        limit: 20,
      }.merge(options)).to_sql
    end

    it 'materializes an id-only intersection and loads statuses.* outside it' do
      sql = build_sql(filters: { exclude_replies: true })
      cte, outer = cte_and_outer(sql)

      # This example is the PostgreSQL 12+ shape. Servers older than 12 are covered below.
      expect(Status.connection.database_version).to be >= 120_000
      expect(sql).to include('WITH matched_ids AS MATERIALIZED (')
      expect(cte).to match(/SELECT "statuses"\."id"/)
      expect(cte).to include('INNER JOIN "statuses_tags"')
      expect(cte).to include('"statuses"."account_id" = 1')
      expect(cte).to include('"statuses_tags"."tag_id" = 2589383')
      expect(cte).to include('"statuses"."deleted_at" IS NULL')
      expect(cte).to include('"statuses"."expired_at" IS NULL')
      expect(cte).to include('"statuses"."visibility" IN (0, 1)')
      expect(cte).not_to include('statuses.*')
      expect(cte).not_to match(/SELECT "statuses"\.\*/)
      expect(cte).not_to match(/\bORDER BY\b/i)
      expect(cte).not_to match(/\bLIMIT\b/i)
      expect(cte).not_to include('statuses.reply')
      expect(sql).to include(') SELECT statuses.* FROM statuses')
      expect(outer).to include('INNER JOIN matched_ids ON matched_ids.id = statuses.id')
      expect(outer).to include('statuses.reply = FALSE')
      expect(outer).to include('statuses.in_reply_to_account_id = statuses.account_id')
      expect(outer).to include('ORDER BY statuses.id DESC')
      expect(outer).to include('LIMIT 20')
      expect(sql.scan(/\bLIMIT\b/).size).to eq 1
    end

    it 'keeps exclude_reblogs on the outer query' do
      cte, outer = cte_and_outer(build_sql(filters: { exclude_reblogs: true }))

      expect(cte).not_to include('reblog_of_id IS NULL')
      expect(outer).to include('statuses.reblog_of_id IS NULL')
    end

    it 'puts max_id and since_id bounds in the CTE and limits outside' do
      cte, outer = cte_and_outer(build_sql(page: { max_id: 500, since_id: 120 }))

      expect(cte).to include('"statuses"."id" < 500')
      expect(cte).to include('"statuses"."id" > 120')
      expect(cte).not_to match(/\bLIMIT\b/i)
      expect(outer).to include('ORDER BY statuses.id DESC')
      expect(outer).to include('LIMIT 20')
    end

    it 'uses an ascending outer page for min_id and ignores since_id' do
      cte, outer = cte_and_outer(build_sql(page: { min_id: 200, max_id: 800, since_id: 600 }))

      expect(cte).to include('"statuses"."id" > 200')
      expect(cte).to include('"statuses"."id" < 800')
      expect(cte).not_to include('"statuses"."id" > 600')
      expect(outer).to include('ORDER BY statuses.id ASC')
      expect(outer).to include('LIMIT 20')
    end

    it 'writes a plain CTE on a PostgreSQL 11 server version' do
      allow(Status.connection).to receive(:database_version).and_return(110_000)

      sql = build_sql(filters: { exclude_replies: true })
      cte, outer = cte_and_outer(sql)

      expect(sql).to include('WITH matched_ids AS (')
      expect(sql).not_to include('MATERIALIZED')
      expect(cte).to match(/SELECT "statuses"\."id"/)
      expect(cte).not_to include('statuses.*')
      expect(sql).to include(') SELECT statuses.* FROM statuses')
      expect(outer).to include('statuses.reply = FALSE')
      expect(outer).to include('ORDER BY statuses.id DESC')
      expect(outer).to include('LIMIT 20')
    end

    it 'rejects non-integer bounds and tag ids instead of interpolating them' do
      expect do
        build_sql(page: { max_id: '20; DROP TABLE statuses' })
      end.to raise_error(ArgumentError)

      expect do
        build_sql(tag_id: '2589383 OR 1=1')
      end.to raise_error(ArgumentError)
    end
  end

  describe 'results' do
    let(:author) { Fabricate(:account, username: 'tagged_author') }
    let(:viewer) { Fabricate(:account, username: 'tagged_viewer') }
    let(:stranger) { Fabricate(:account, username: 'tagged_stranger') }
    let(:blocked_author) { Fabricate(:account, username: 'tagged_blocked') }
    let(:tag) { Fabricate(:tag, name: 'sparsetag') }

    def tag_status(status, hashtag = tag)
      status.tags << hashtag
      status
    end

    def make_status(id, **attrs)
      Fabricate(:status, { account: author, id: id, text: "status-#{id}", visibility: :public }.merge(attrs))
    end

    let!(:public_status) { tag_status(make_status(1_000)) }
    let!(:unlisted_status) { tag_status(make_status(1_001, visibility: :unlisted)) }
    let!(:private_status) { tag_status(make_status(1_002, visibility: :private)) }
    let!(:direct_status) { tag_status(make_status(1_003, visibility: :direct)) }
    let!(:mentioned_direct) { tag_status(make_status(1_004, visibility: :direct)) }
    let!(:limited_status) { tag_status(make_status(1_005, visibility: :limited)) }
    let!(:mentioned_limited) { tag_status(make_status(1_006, visibility: :limited)) }
    let!(:personal_status) { tag_status(make_status(1_007, visibility: :personal)) }
    let!(:mutual_status) { tag_status(make_status(1_008, visibility: :mutual)) }
    let!(:reply_to_other) { tag_status(make_status(1_009, thread: Fabricate(:status, account: stranger, text: 'other parent'))) }
    let!(:self_reply) { tag_status(make_status(1_010, thread: Fabricate(:status, account: author, text: 'self parent'))) }
    let!(:reblog_status) { tag_status(make_status(1_011, reblog: Fabricate(:status, account: stranger, text: 'boosted'))) }
    let!(:blocked_reblog) { tag_status(make_status(1_012, reblog: Fabricate(:status, account: blocked_author, text: 'blocked boost'))) }
    let!(:expired_status) do
      status = tag_status(make_status(1_013, text: 'expired-status'))
      status.update_columns(expired_at: Time.now.utc)
      status
    end
    let!(:deleted_status) do
      status = tag_status(make_status(1_014, text: 'deleted-status'))
      status.update_columns(deleted_at: Time.now.utc)
      status
    end
    let!(:other_tag_status) { tag_status(make_status(1_015, text: 'other-tag'), Fabricate(:tag, name: 'othertag')) }
    let!(:untagged_status) { make_status(1_016, text: 'untagged') }
    let!(:foreign_status) { tag_status(Fabricate(:status, account: stranger, id: 1_017, text: 'foreign', visibility: :public)) }

    before do
      Fabricate(:mention, account: viewer, status: mentioned_direct)
      Fabricate(:mention, account: viewer, status: mentioned_limited)
    end

    def expect_legacy_match(viewer:, **options)
      args = { account: author, viewer: viewer, tag: tag, limit: 40 }.merge(options)
      expect(query_rows(**args)).to eq(legacy_rows(**args))
    end

    it 'matches the legacy relation for tag filters and pagination' do
      cases = [
        {},
        { exclude_replies: true },
        { exclude_reblogs: true },
        { exclude_replies: true, exclude_reblogs: true },
        { hide_personal: true },
        { hide_personal: true, exclude_replies: true, exclude_reblogs: true },
        { page: { max_id: 1_010 } },
        { page: { since_id: 1_004 } },
        { page: { min_id: 1_004 } },
        { page: { min_id: 1_004, max_id: 1_012 } },
        { page: { min_id: 1_004, since_id: 1_010 } },
        { exclude_replies: true, page: { max_id: 1_012 } },
        { exclude_replies: true, exclude_reblogs: true, page: { min_id: 1_000, max_id: 1_013 } },
        { limit: 3 },
        { exclude_replies: true, limit: 2 },
      ]

      cases.each do |options|
        expect_legacy_match(viewer: nil, **options)
        expect_legacy_match(viewer: author, **options)
        expect_legacy_match(viewer: viewer, **options)
      end
    end

    it 'matches the legacy relation for a follower' do
      viewer.follow!(author)

      [nil, { exclude_replies: true }, { page: { min_id: 1_001, max_id: 1_011 } }].each do |options|
        expect_legacy_match(viewer: viewer, **(options || {}))
      end
    end

    it 'matches the legacy relation when the viewer blocks the boosted account' do
      viewer.block!(blocked_author)

      expect_legacy_match(viewer: viewer)
      expect_legacy_match(viewer: viewer, exclude_reblogs: true)

      rows = query_rows(account: author, viewer: viewer, tag: tag, limit: 40)
      expect(rows.map(&:first)).not_to include(blocked_reblog.id)
      expect(rows.map(&:first)).to include(public_status.id)
    end

    it 'keeps self-replies when exclude_replies drops replies to other accounts' do
      rows = query_rows(account: author, viewer: author, tag: tag, limit: 40, exclude_replies: true)
      ids = rows.map(&:first)

      expect(ids).to include(self_reply.id)
      expect(ids).not_to include(reply_to_other.id)
      expect(rows).to eq(legacy_rows(account: author, viewer: author, tag: tag, limit: 40, exclude_replies: true))
    end

    it 'loads full status rows for the surviving ids' do
      rows = query_rows(account: author, viewer: author, tag: tag, limit: 5)
      expect(rows).to eq([
        [expired_status.id, 'expired-status'],
        [blocked_reblog.id, 'status-1012'],
        [reblog_status.id, 'status-1011'],
        [self_reply.id, 'status-1010'],
        [reply_to_other.id, 'status-1009'],
      ])
      expect(rows.map(&:last)).to all(be_present)
      expect(ids_from(rows)).not_to include(deleted_status.id, other_tag_status.id, untagged_status.id, foreign_status.id)
    end

    it 'fills the limit from later rows when leading candidates are replies' do
      25.times do |index|
        tag_status(make_status(5_000 + index, thread: Fabricate(:status, account: stranger, text: "parent-#{index}")))
      end
      posts = [3_001, 3_002, 3_003, 3_004, 3_005].map { |id| tag_status(make_status(id, text: "kept-#{id}")) }

      rows = query_rows(account: author, viewer: author, tag: tag, limit: 5, exclude_replies: true)
      expect(rows).to eq(posts.reverse.map { |status| [status.id, status.text] })
      expect(rows).to eq(legacy_rows(account: author, viewer: author, tag: tag, limit: 5, exclude_replies: true))
    end

    def ids_from(rows)
      rows.map(&:first)
    end
  end
end
