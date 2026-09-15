# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::PendingTargetFeed do
  def create_batch
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
  end

  it 'walks pending targets in position order without loading the whole batch' do
    batch = create_batch
    5.times { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }
    batch.targets.create!(target_key_hash: 'queued', position: 99, state: :queued)

    feed = described_class.new(batch.id, window: 2)
    ids = []
    ids << feed.shift[:id] while feed.remaining?

    expect(ids).to eq(batch.targets.where(state: :pending).order(:position).pluck(:id))
  end

  it 'starts after a reconstructable position cursor and wraps to the first pending row' do
    batch = create_batch
    rows = 3.times.map { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }

    feed = described_class.new(batch.id, after_position: rows[1].position, window: 2)
    first = feed.shift

    expect(first[:id]).to eq rows[2].id
    expect(feed.shift[:id]).to eq rows[0].id
    expect(feed.shift[:id]).to eq rows[1].id
    expect(feed.remaining?).to be false
  end

  it 'does not wrap and re-yield when the walk started at the first pending row' do
    batch = create_batch
    3.times { |position| batch.targets.create!(target_key_hash: "p#{position}", position: position) }

    feed = described_class.new(batch.id, window: 2)
    ids = []
    ids << feed.shift[:id] while feed.remaining?

    expect(ids.size).to eq 3
    expect(ids.uniq.size).to eq 3
    expect(feed.remaining?).to be false
  end
end
