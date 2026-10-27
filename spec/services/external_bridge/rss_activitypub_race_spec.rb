# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'RSS ActivityPub candidate races' do
  # Two connections have to commit. A wrapped example transaction would hide
  # the row lock from the other session until the example ended.
  self.use_transactional_tests = false

  let(:feed_url) { 'https://feeds.example/race-activitypub.xml' }
  let(:old_url) { 'https://posts.example/@alice/123' }
  let(:new_url) { 'https://posts.example/@alice/124' }

  before do
    ActiveRecord::Base.connection_pool.lock_thread = false
    @source = ExternalSource.create!(protocol: 'rss', canonical_key: feed_url, title: 'Race')
    @resource = ExternalResource.create!(
      external_source: @source,
      protocol: 'rss',
      canonical_key: "feed:#{feed_url}\nitem:stable-guid",
      canonical_url: old_url,
      title: 'Post',
      activitypub_candidate_url: old_url,
      activitypub_state: 'unknown'
    )
  end

  after do
    ActiveRecord::Base.connection_pool.lock_thread = true
    if @source
      ExternalActor.where(native_id: @source.canonical_key).delete_all
      ExternalResource.where(external_source_id: @source.id).delete_all
      ExternalSource.where(id: @source.id).delete_all
    end
  end

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def finish(threads)
    Array(threads).compact.each { |thread| thread.join(10) }
  end

  def ingest_replacement!
    feed = ExternalBridge::RSS::Parser.parse!(<<~XML)
      <rss><channel><title>Example</title>
        <item><guid>stable-guid</guid><title>Post</title><link>#{new_url}</link></item>
      </channel></rss>
    XML
    ExternalBridge::RSS::Ingest.new.apply_public!(@source, feed, ExternalBridge::RSS::Response.new(code: 200))
  end

  def waiting_for_resource_lock?
    sql = <<~SQL.squish
      SELECT COUNT(*) FROM pg_locks
      WHERE relation = 'external_resources'::regclass AND NOT granted
    SQL
    ActiveRecord::Base.connection.select_value(sql).to_i.positive?
  end

  def wait_for_resource_lock
    deadline = Time.current + 3
    loop do
      return if waiting_for_resource_lock?
      raise 'probe did not wait on the resource row lock' if Time.current > deadline

      sleep 0.05
    end
  end

  it 'discards an in-flight probe when ingest commits a new candidate url' do
    threads = []
    release = Queue.new
    arrived = Queue.new
    stub_request(:get, old_url).to_return(
      status: 200,
      body: {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        'id' => 'https://posts.example/users/alice/statuses/123',
        'type' => 'Note',
      }.to_json,
      headers: { 'Content-Type' => 'application/activity+json' }
    )
    allow_any_instance_of(ExternalBridge::RSS::ActivityPub::ProbeSource).to receive(:before_probe_commit).and_wrap_original do |method, *args|
      arrived << true
      release.pop
      method.call(*args)
    end

    threads << Thread.new do
      with_connection { ExternalBridge::RSS::ActivityPub::ProbeSource.new.send(:probe_one, @resource.id) }
    end
    arrived.pop
    ingest_replacement!
    release << true
    finish(threads)

    @resource.reload
    expect(@resource.activitypub_candidate_url).to eq new_url
    expect(@resource.activitypub_state).to eq 'unknown'
    expect(@resource.activitypub_object_id).to be_nil
    expect(@resource.activitypub_object_id_status).to be_nil
    expect(a_request(:get, new_url)).not_to have_been_made
  ensure
    release << true if release && release.num_waiting.positive?
    finish(threads)
  end

  it 'does not attach a stale probe lease or object id to the replacement url' do
    threads = []
    probe_go = Queue.new
    ingest_go = Queue.new
    probe_read = Queue.new
    ingest_locked = Queue.new
    stub_request(:get, old_url).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/activity+json' })
    stub_request(:get, new_url).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/activity+json' })

    allow_any_instance_of(ExternalBridge::RSS::ActivityPub::ProbeSource).to receive(:before_probe_claim).and_wrap_original do |method, *args|
      probe_read << true
      probe_go.pop
      method.call(*args)
    end
    allow_any_instance_of(ExternalBridge::RSS::Ingest).to receive(:before_activitypub_commit).and_wrap_original do |method, *args|
      ingest_locked << true
      ingest_go.pop
      method.call(*args)
    end

    threads << Thread.new do
      with_connection { ExternalBridge::RSS::ActivityPub::ProbeSource.new.send(:probe_one, @resource.id) }
    end
    probe_read.pop
    threads << Thread.new do
      with_connection { ingest_replacement! }
    end
    ingest_locked.pop
    probe_go << true
    wait_for_resource_lock
    ingest_go << true
    finish(threads)

    @resource.reload
    expect(@resource.activitypub_candidate_url).to eq new_url
    expect(@resource.activitypub_state).to eq 'unknown'
    expect(@resource.activitypub_object_id).to be_nil
    expect(@resource.activitypub_next_check_at).to be <= Time.current
    expect(a_request(:get, old_url)).not_to have_been_made
    expect(a_request(:get, new_url)).not_to have_been_made
  ensure
    probe_go << true if probe_go && probe_go.num_waiting.positive?
    ingest_go << true if ingest_go && ingest_go.num_waiting.positive?
    finish(threads)
  end
end
