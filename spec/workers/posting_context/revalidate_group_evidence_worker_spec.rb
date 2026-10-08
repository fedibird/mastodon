# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::RevalidateGroupEvidenceWorker do
  let(:account) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'mitra.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://mitra.example/users/group',
      inbox_url: 'https://mitra.example/users/group/inbox',
      affiliations_url: 'https://mitra.example/users/group/affiliations'
    )
  end
  let(:registry) { PostingContext::RevalidationRegistry.new }
  let(:requester) { Fabricate(:user) }

  after do
    RedisConfiguration.with do |redis|
      redis.scan_each(match: 'posting_context:revalidation:v1:*') { |key| redis.del(key) }
    end
  end

  it 'publishes the service result for the current request only' do
    created = registry.request!(account, requester: requester)
    result = PostingContext::RevalidateGroupEvidenceService::Result.new(state: 'partial', actor: 'refreshed', affiliations: 'failed')
    expect(PostingContext::RevalidateGroupEvidenceService).to receive(:new).and_return(instance_double(PostingContext::RevalidateGroupEvidenceService, call: result))

    described_class.new.perform(account.id, created.payload[:request_id])

    expect(registry.read(account)).to include(state: 'partial', actor: 'refreshed', affiliations: 'failed', request_id: created.payload[:request_id])
  end

  it 'keeps the lease during a long refresh and does not start a second sync' do
    stub_const('PostingContext::RevalidateGroupEvidenceWorker::HEARTBEAT_INTERVAL', 0.01)
    created = registry.request!(account, requester: requester)
    calls = 0
    allow(PostingContext::RevalidateGroupEvidenceService).to receive(:new).and_return(instance_double(PostingContext::RevalidateGroupEvidenceService).tap { |service|
      allow(service).to receive(:call) do |_account, on_step: nil, request_id: nil|
        expect(request_id).to eq created.payload[:request_id]
        calls += 1
        RedisConfiguration.with { |redis| redis.expire("posting_context:revalidation:v1:#{account.id}:lock", 1) }
        sleep 0.08
        RedisConfiguration.with { |redis| expect(redis.ttl("posting_context:revalidation:v1:#{account.id}:lock")).to be > 1 }
        expect(on_step.call).to be true
        expect(registry.request!(account, requester: requester).status).to eq :inflight
        described_class.new.perform(account.id, 'someone-else')
        PostingContext::RevalidateGroupEvidenceService::Result.new(state: 'completed', actor: 'refreshed', affiliations: 'refreshed')
      end
    })

    described_class.new.perform(account.id, created.payload[:request_id])

    expect(calls).to eq 1
    expect(registry.read(account)).to include(state: 'completed', request_id: created.payload[:request_id])
  end

  it 'does not let a stale worker replace a newer snapshot' do
    first = registry.request!(account, requester: requester)
    registry.mark_running!(account.id, first.payload[:request_id])
    registry.finish!(account.id, first.payload[:request_id], PostingContext::RevalidateGroupEvidenceService::Result.new(state: 'failed', actor: 'failed', affiliations: 'failed'))
    RedisConfiguration.with { |redis| redis.del("posting_context:revalidation:v1:#{account.id}:cooldown") }
    second = registry.request!(account, requester: requester)
    account.update_columns(can_create_affiliation: 'from-new-worker')
    expect(PostingContext::RevalidateGroupEvidenceService).not_to receive(:new)

    described_class.new.perform(account.id, first.payload[:request_id])

    expect(account.reload.can_create_affiliation).to eq 'from-new-worker'
    expect(registry.read(account)).to include(state: 'queued', request_id: second.payload[:request_id])
  end

  it 'does not publish a result after a newer request owns the account' do
    first = registry.request!(account, requester: requester)
    registry.mark_running!(account.id, first.payload[:request_id])
    registry.finish!(account.id, first.payload[:request_id], PostingContext::RevalidateGroupEvidenceService::Result.new(state: 'failed', actor: 'failed', affiliations: 'failed'))
    RedisConfiguration.with { |redis| redis.del("posting_context:revalidation:v1:#{account.id}:cooldown") }
    second = registry.request!(account, requester: requester)
    expect(PostingContext::RevalidateGroupEvidenceService).not_to receive(:new)

    described_class.new.perform(account.id, first.payload[:request_id])

    expect(registry.read(account)[:request_id]).to eq second.payload[:request_id]
    expect(registry.read(account)[:state]).to eq 'queued'
  end
end
