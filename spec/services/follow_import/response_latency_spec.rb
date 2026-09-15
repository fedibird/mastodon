# frozen_string_literal: true

require 'rails_helper'

# Accept/Reject already stamp completed_at. Request → response latency uses
# request_started_at (else enqueued_at), not worker finished_at, so a
# bookkeeping race does not invent a negative latency.
RSpec.describe 'Follow Import response latency from existing timestamps' do
  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 1, resolved_target_count: 0, unresolved_target_count: 1)
  end
  let(:target) do
    batch.targets.create!(target_key_hash: 'key', destination_domain: 'example.com', position: 0)
  end

  def observation_at(request_started_at, finished_at: nil)
    finished_at ||= request_started_at + 1.second
    FollowImportTransportObservation.create!(
      batch_id: batch.id,
      target_id: target.id,
      phase: 'activitypub_delivery',
      destination_domain: 'example.com',
      endpoint_origin: 'https://example.com',
      started_at: request_started_at - 0.2,
      finished_at: finished_at,
      duration_ms: 1200,
      request_started_at: request_started_at,
      request_finished_at: request_started_at + 0.08,
      request_duration_ms: 80,
      outcome: 'http_success',
      http_status: 200,
      metadata: {},
      created_at: finished_at
    )
  end

  it 'can compute request → Accept latency from completed_at and request_started_at' do
    requested = Time.utc(2026, 9, 1, 12, 0, 0)
    accepted  = requested + 45.seconds
    observation_at(requested, finished_at: accepted + 1.second)
    FollowImport::TargetTransitionService.new.mark_queued(target)
    FollowImport::TargetTransitionService.new.mark_accepted(target, at: accepted)

    origin = FollowImportTransportObservation.where(target_id: target.id, phase: 'activitypub_delivery', outcome: 'http_success').minimum(:request_started_at)
    latency = target.reload.completed_at - origin
    expect(latency).to eq 45.seconds
    expect(target.delivered_at).to be_nil
  end

  it 'stays non-negative when Accept races ahead of worker finished_at' do
    requested = Time.utc(2026, 9, 1, 12, 0, 0)
    accepted  = requested + 1.second
    observation_at(requested, finished_at: requested + 2.seconds)
    FollowImport::TargetTransitionService.new.mark_queued(target)
    FollowImport::TargetTransitionService.new.mark_accepted(target, at: accepted)

    row = FollowImportTransportObservation.find_by!(target_id: target.id, phase: 'activitypub_delivery')
    expect(target.reload.completed_at - row.request_started_at).to eq 1.second
    expect(target.completed_at).to be < row.finished_at
  end
end
