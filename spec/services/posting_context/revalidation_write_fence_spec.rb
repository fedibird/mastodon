# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe PostingContext::RevalidationWriteFence do
  # Threads must observe committed rows. An outer test transaction would also
  # keep the advisory lock until the example ended.
  self.use_transactional_tests = false

  let(:domain) { "fence-#{SecureRandom.hex(4)}.example" }
  let(:uri) { "https://#{domain}/users/group" }
  let(:url_a) { "https://#{domain}/users/group/affiliations-a" }
  let(:url_b) { "https://#{domain}/users/group/affiliations-b" }
  let(:requester) { Fabricate(:user) }
  let(:registry) { PostingContext::RevalidationRegistry.new }
  let(:account) do
    Fabricate(
      :account,
      username: 'group',
      domain: domain,
      actor_type: 'Group',
      protocol: :activitypub,
      uri: uri,
      inbox_url: "#{uri}/inbox",
      affiliations_url: "https://#{domain}/users/group/affiliations",
      can_create_affiliation: 'member',
      can_view_affiliation: 'member',
      permission_definitions_fetched_at: Time.utc(2026, 1, 1),
      affiliations_fetched_at: Time.utc(2026, 1, 1)
    )
  end

  before do
    ActiveRecord::Base.connection_pool.lock_thread = false
    GroupAffiliation.create!(
      group_account: account,
      subject_uri: 'https://remote.example/users/old',
      relationship: 'member'
    )
  end

  after do
    ActiveRecord::Base.connection_pool.lock_thread = true
    GroupAffiliation.where(group_account_id: Account.where(domain: domain).select(:id)).delete_all
    Account.where(domain: domain).find_each(&:destroy!)
    if requester&.account
      requester.account.destroy!
    end
    requester&.destroy!
    RedisConfiguration.with do |redis|
      redis.scan_each(match: 'posting_context:revalidation:v1:*') { |key| redis.del(key) }
    end
  end

  it 'does not let an actor fetch that lost its lease overwrite a newer snapshot' do
    documents = { actor: actor_document('from-a', url_a) }
    stub_remote_documents(documents)
    release = Queue.new
    entered = Queue.new
    pause_during_actor_fetch(release, entered)
    request_a = accept_request!
    holder = {}
    thread = nil

    begin
      thread = Thread.new do
        Thread.current[:revalidation_worker] = 'A'
        ActiveRecord::Base.connection_pool.with_connection do
          holder[:result] = run_service(request_a)
        end
      rescue StandardError => e
        holder[:error] = e
      ensure
        checkin_thread_redis
      end

      expect(entered.pop(timeout: 10)).to eq :actor
      snapshot = Timeout.timeout(20) { run_newer_request!(documents) }
      release << true
      expect(thread.join(20)).to be_present
      raise holder[:error] if holder[:error]

      expect(snapshot_unchanged(snapshot)).to be true
    ensure
      release << true
      thread&.join(5)
    end
  end

  it 'does not let an affiliation fetch that lost its lease overwrite a newer snapshot' do
    documents = { actor: actor_document('from-a', url_a) }
    stub_remote_documents(documents)
    release = Queue.new
    entered = Queue.new
    pause_during_affiliation_fetch(release, entered)
    request_a = accept_request!
    holder = {}
    thread = nil

    begin
      thread = Thread.new do
        Thread.current[:revalidation_worker] = 'A'
        ActiveRecord::Base.connection_pool.with_connection do
          holder[:result] = run_service(request_a)
        end
      rescue StandardError => e
        holder[:error] = e
      ensure
        checkin_thread_redis
      end

      expect(entered.pop(timeout: 10)).to eq :affiliations
      snapshot = Timeout.timeout(20) { run_newer_request!(documents) }
      release << true
      expect(thread.join(20)).to be_present
      raise holder[:error] if holder[:error]

      expect(snapshot_unchanged(snapshot)).to be true
    ensure
      release << true
      thread&.join(5)
    end
  end

  def run_newer_request!(documents)
    RedisConfiguration.with do |redis|
      redis.del("posting_context:revalidation:v1:#{account.id}:lock")
      redis.del("posting_context:revalidation:v1:#{account.id}:cooldown")
    end
    documents[:actor] = actor_document('from-b', url_b)
    request_b = accept_request!
    expect(request_b).to be_present
    run_service(request_b)
    account.reload
    documents[:actor] = actor_document('from-a', url_a)
    {
      can_create_affiliation: account.can_create_affiliation,
      permission_definitions_fetched_at: account.permission_definitions_fetched_at,
      affiliations_fetched_at: account.affiliations_fetched_at,
      rows: account.group_affiliations.pluck(:subject_uri, :relationship),
    }
  end

  def snapshot_unchanged(snapshot)
    account.reload
    expect(account.can_create_affiliation).to eq 'from-b'
    expect(account.can_create_affiliation).to eq snapshot[:can_create_affiliation]
    expect(account.permission_definitions_fetched_at).to eq snapshot[:permission_definitions_fetched_at]
    expect(account.affiliations_fetched_at).to eq snapshot[:affiliations_fetched_at]
    expect(account.group_affiliations.pluck(:subject_uri, :relationship)).to eq [['https://remote.example/users/b', 'from-b']]
    expect(account.group_affiliations.pluck(:subject_uri, :relationship)).to eq snapshot[:rows]
    true
  end

  def accept_request!
    created = registry.request!(account, requester: requester)
    expect(created.status).to eq :created
    expect(registry.mark_running!(account.id, created.payload[:request_id])).to be true
    created.payload[:request_id]
  end

  def run_service(request_id)
    PostingContext::RevalidateGroupEvidenceService.new.call(
      account,
      request_id: request_id,
      on_step: -> { registry.renew!(account.id, request_id) }
    )
  end

  def pause_during_actor_fetch(release, entered)
    allow_any_instance_of(ActivityPub::FetchRemoteAccountService).to receive(:fetch_resource).and_wrap_original do |method, *args, **kwargs|
      if Thread.current[:revalidation_worker] == 'A'
        entered << :actor
        release.pop
      end
      method.call(*args, **kwargs)
    end
  end

  def pause_during_affiliation_fetch(release, entered)
    allow_any_instance_of(ActivityPub::FetchGroupAffiliationsService).to receive(:fetch_resource_without_id_validation).and_wrap_original do |method, *args, **kwargs|
      if Thread.current[:revalidation_worker] == 'A'
        entered << :affiliations
        release.pop
      end
      method.call(*args, **kwargs)
    end
  end

  def stub_remote_documents(documents)
    stub_request(:get, %r{/\.well-known/webfinger\?resource=acct:group@#{Regexp.escape(domain)}}).to_return(
      status: 200,
      body: Oj.dump(subject: "acct:group@#{domain}", links: [{ rel: 'self', href: uri }]),
      headers: { 'Content-Type' => 'application/jrd+json' }
    )
    stub_request(:get, uri).to_return do
      {
        status: 200,
        body: Oj.dump(documents[:actor]),
        headers: { 'Content-Type' => 'application/activity+json' },
      }
    end
    stub_collection(url_a, 'https://remote.example/users/a', 'from-a')
    stub_collection(url_b, 'https://remote.example/users/b', 'from-b')
  end

  def stub_collection(url, subject, relationship)
    stub_request(:get, url).to_return(
      status: 200,
      body: Oj.dump(
        '@context' => 'https://www.w3.org/ns/activitystreams',
        'type' => 'OrderedCollection',
        'orderedItems' => [
          {
            'type' => 'Relationship',
            'subject' => subject,
            'relationship' => relationship,
            'object' => uri,
          },
        ]
      ),
      headers: { 'Content-Type' => 'application/activity+json' }
    )
  end

  def actor_document(can_create, affiliations_url)
    {
      '@context' => 'https://www.w3.org/ns/activitystreams',
      'id' => uri,
      'type' => 'Group',
      'preferredUsername' => 'group',
      'inbox' => "#{uri}/inbox",
      'canCreate' => can_create,
      'canView' => 'member',
      'affiliations' => affiliations_url,
      'publicKey' => {
        'id' => "#{uri}#main-key",
        'owner' => uri,
        'publicKeyPem' => account.public_key,
      },
    }
  end

  def checkin_thread_redis
    leased = Thread.current[:redis]
    return unless leased

    RedisConfiguration.pool.checkin
    Thread.current[:redis] = nil
  end
end
