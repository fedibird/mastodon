# frozen_string_literal: true

require 'rails_helper'

# Accept/Reject already stamp completed_at. Delivery → response latency is
# recovered by joining that timestamp to the delivery observation; no extra
# column is required, including when Accept/Reject races ahead of delivered_at.
RSpec.describe 'Follow Import response latency from existing timestamps' do
  let(:batch) do
    FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc, mode: :merge,
                              target_count: 1, resolved_target_count: 0, unresolved_target_count: 1)
  end
  let(:target) do
    batch.targets.create!(target_key_hash: 'key', destination_domain: 'example.com', position: 0)
  end

  def observation_at(finished_at)
    FollowImportTransportObservation.create!(
      batch_id: batch.id,
      target_id: target.id,
      phase: 'activitypub_delivery',
      destination_domain: 'example.com',
      endpoint_origin: 'https://example.com',
      started_at: finished_at - 1.second,
      finished_at: finished_at,
      duration_ms: 1000,
      outcome: 'http_success',
      http_status: 200,
      metadata: {},
      created_at: finished_at
    )
  end

  it 'can compute delivery → Accept latency from completed_at and the delivery observation' do
    delivered = Time.utc(2026, 9, 1, 12, 0, 0)
    accepted  = delivered + 45.seconds
    observation_at(delivered)
    FollowImport::TargetTransitionService.new.mark_queued(target)
    FollowImport::TargetTransitionService.new.mark_accepted(target, at: accepted)

    latency = target.reload.completed_at - FollowImportTransportObservation.where(target_id: target.id, phase: 'activitypub_delivery', outcome: 'http_success').minimum(:finished_at)
    expect(latency).to eq 45.seconds
    expect(target.delivered_at).to be_nil
  end

  it 'can compute delivery → Reject latency when Reject arrives before delivery bookkeeping' do
    delivered = Time.utc(2026, 9, 1, 12, 0, 0)
    rejected  = delivered - 5.seconds
    observation_at(delivered)
    FollowImport::TargetTransitionService.new.mark_queued(target)
    FollowImport::TargetTransitionService.new.mark_rejected(target, at: rejected)

    latency = target.reload.completed_at - FollowImportTransportObservation.where(target_id: target.id, phase: 'activitypub_delivery', outcome: 'http_success').minimum(:finished_at)
    expect(latency).to eq(-5.seconds)
    expect(target.state).to eq 'rejected'
    expect(target.delivered_at).to be_nil
  end
end
