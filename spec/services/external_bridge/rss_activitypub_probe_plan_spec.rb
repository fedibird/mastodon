# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'RSS ActivityPub probe query shape' do
  # ANALYZE has to see the inserted history. The example transaction would
  # hide those rows from a snapshot taken by ANALYZE.
  self.use_transactional_tests = false

  before do
    ActiveRecord::Base.connection_pool.lock_thread = false
    @source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://bulk.example/feed.xml', title: 'Bulk')
  end

  after do
    ActiveRecord::Base.connection_pool.lock_thread = true
    if @source
      ExternalResource.where(external_source_id: @source.id).delete_all
      ExternalSource.where(id: @source.id).delete_all
    end
  end

  it 'plans due probes and verified-item checks from partial indexes across a large history' do
    connection = ExternalResource.connection
    connection.execute(<<~SQL.squish)
      INSERT INTO external_resources (
        external_source_id, protocol, canonical_key, truncated, media_candidates, keywords,
        activitypub_state, activitypub_explicit, activitypub_evidence_version,
        activitypub_candidate_url, activitypub_next_check_at, created_at, updated_at
      )
      SELECT #{@source.id}, 'rss', 'bulk:' || i, false, '[]'::jsonb, '[]'::jsonb,
             'unknown', false, 0,
             'https://news.example/item/' || i, TIMESTAMP '1970-01-01 00:00:00', NOW(), NOW()
      FROM generate_series(1, 200000) AS i
    SQL
    2.times do |index|
      ExternalResource.create!(
        external_source: @source, protocol: 'rss', canonical_key: "explicit-due-#{index}",
        activitypub_candidate_url: "https://posts.example/users/alice/statuses/#{index}",
        activitypub_explicit: true, activitypub_state: 'unknown'
      )
    end
    ExternalResource.create!(
      external_source: @source, protocol: 'rss', canonical_key: 'verified-item',
      activitypub_candidate_url: 'https://posts.example/users/alice/statuses/2',
      activitypub_explicit: true, activitypub_state: 'verified',
      activitypub_object_id: 'https://posts.example/users/alice/statuses/2',
      activitypub_object_id_status: 'self_reported', activitypub_object_type: 'Note',
      activitypub_next_check_at: 7.days.from_now
    )
    connection.execute('ANALYZE external_resources')

    due = ExternalBridge::RSS::ActivityPub::DueResources.new(@source.reload)
    plans = {
      explicit: explain(due.explicit_probe_scope),
      ordinary: explain(due.ordinary_probe_scope),
      verified: explain(ExternalBridge::RSS::ActivityPub::DueResources.verified_items(@source)),
    }
    File.write('/opt/cursor/artifacts/rss-activitypub-probe-explain.txt', plans.map { |name, plan| "#{name}\n#{plan}" }.join("\n\n"))

    plans.each do |name, plan|
      expect(plan).to match(/Index Scan|Index Only Scan|Bitmap Index Scan/), name.to_s
      expect(plan).not_to match(/Seq Scan on external_resources/), "#{name}\n#{plan}"
    end
    expect(plans[:explicit]).to match(/index_external_resources_on_ap_probe_due/)
    expect(plans[:explicit]).to match(/Limit/i)
    expect(plans[:verified]).to match(/index_external_resources_on_ap_item_verified/)

    ids = due.ids
    expect(ids.size).to eq ExternalBridge::RSS::ActivityPub::Limits::MAX_GETS_PER_RUN
    expect(ExternalResource.where(id: ids).pluck(:activitypub_explicit)).to all(be true)
  end

  def explain(relation)
    ExternalResource.connection.unprepared_statement do
      ExternalResource.connection.exec_query("EXPLAIN #{relation.to_sql}").rows.flatten.join("\n")
    end
  end
end
