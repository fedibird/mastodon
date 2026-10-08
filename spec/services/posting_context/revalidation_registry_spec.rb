# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::RevalidationRegistry do
  let(:registry) { described_class.new }
  let(:requester) { Fabricate(:user) }
  let(:account) do
    Fabricate(
      :account,
      username: 'group',
      domain: 'mitra.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://mitra.example/users/group',
      inbox_url: 'https://mitra.example/users/group/inbox'
    )
  end

  after do
    RedisConfiguration.with do |redis|
      redis.scan_each(match: 'posting_context:revalidation:v1:*') { |key| redis.del(key) }
    end
  end

  it 'keeps a second request on the same in-flight job' do
    first = registry.request!(account, requester: requester)
    second = registry.request!(account, requester: requester)

    expect(first.status).to eq :created
    expect(second.status).to eq :inflight
    expect(second.payload[:request_id]).to eq first.payload[:request_id]
    expect(second.payload[:state]).to eq 'queued'
  end

  it 'rejects another request during the cooldown after the job finishes' do
    created = registry.request!(account, requester: requester)
    registry.mark_running!(account.id, created.payload[:request_id])
    registry.finish!(account.id, created.payload[:request_id], result('completed', 'refreshed', 'refreshed'))

    follow_up = registry.request!(account, requester: requester)

    expect(follow_up.status).to eq :cooldown
    expect(follow_up.retry_after).to be_positive
  end

  it 'does not let an older request overwrite a newer one' do
    first = registry.request!(account, requester: requester)
    registry.mark_running!(account.id, first.payload[:request_id])
    registry.finish!(account.id, first.payload[:request_id], result('failed', 'failed', 'failed'))
    RedisConfiguration.with { |redis| redis.del("posting_context:revalidation:v1:#{account.id}:cooldown") }

    second = registry.request!(account, requester: requester)
    registry.mark_running!(account.id, second.payload[:request_id])
    expect(registry.finish!(account.id, first.payload[:request_id], result('completed', 'refreshed', 'refreshed'))).to be false

    current = registry.read(account)
    expect(current[:request_id]).to eq second.payload[:request_id]
    expect(current[:state]).to eq 'running'
    expect(current[:actor]).to be_nil
  end

  it 'records a failed state when the lock lease disappears' do
    created = registry.request!(account, requester: requester)
    RedisConfiguration.with { |redis| redis.del("posting_context:revalidation:v1:#{account.id}:lock") }

    current = registry.read(account)

    expect(current[:request_id]).to eq created.payload[:request_id]
    expect(current[:state]).to eq 'failed'
    expect(current[:actor]).to eq 'failed'
  end

  it 'extends the lease for the lock owner and rejects a missing or foreign lock' do
    created = registry.request!(account, requester: requester)
    request_id = created.payload[:request_id]
    expect(registry.mark_running!(account.id, request_id)).to be true

    RedisConfiguration.with do |redis|
      redis.expire("posting_context:revalidation:v1:#{account.id}:lock", 5)
    end
    expect(registry.renew!(account.id, request_id)).to be true
    RedisConfiguration.with do |redis|
      expect(redis.ttl("posting_context:revalidation:v1:#{account.id}:lock")).to be > 5
    end

    RedisConfiguration.with { |redis| redis.del("posting_context:revalidation:v1:#{account.id}:lock") }
    expect(registry.renew!(account.id, request_id)).to be false
    expect(registry.extend_lease!(account.id, request_id)).to be false
    expect(registry.finish!(account.id, request_id, result('completed', 'refreshed', 'refreshed'))).to be false
    expect(registry.read(account)[:state]).to eq 'failed'
  end

  it 'does not update state or a foreign lock when the lease belongs to someone else' do
    created = registry.request!(account, requester: requester)
    request_id = created.payload[:request_id]
    registry.mark_running!(account.id, request_id)
    RedisConfiguration.with do |redis|
      redis.set("posting_context:revalidation:v1:#{account.id}:lock", 'other-request', ex: 30)
    end

    expect(registry.mark_running!(account.id, request_id)).to be false
    expect(registry.renew!(account.id, request_id)).to be false
    expect(registry.extend_lease!(account.id, request_id)).to be false
    expect(registry.finish!(account.id, request_id, result('completed', 'refreshed', 'refreshed'))).to be false

    current = registry.read(account)
    expect(current[:state]).to eq 'running'
    expect(current[:request_id]).to eq request_id
    RedisConfiguration.with do |redis|
      expect(redis.get("posting_context:revalidation:v1:#{account.id}:lock")).to eq 'other-request'
    end
  end

  it 'limits how often one administrator can start revalidation' do
    stub_const('PostingContext::RevalidationRegistry::ADMIN_LIMIT', 1)
    other = Fabricate(
      :account,
      username: 'othergroup',
      domain: 'other.example',
      actor_type: 'Group',
      protocol: :activitypub,
      uri: 'https://other.example/users/group',
      inbox_url: 'https://other.example/users/group/inbox'
    )

    expect(registry.request!(account, requester: requester).status).to eq :created
    limited = registry.request!(other, requester: requester)

    expect(limited.status).to eq :limited
    expect(limited.retry_after).to be_positive
  end

  def result(state, actor, affiliations)
    PostingContext::RevalidateGroupEvidenceService::Result.new(state: state, actor: actor, affiliations: affiliations)
  end
end
