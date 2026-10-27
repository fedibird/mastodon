# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

# Two purges commit in a fixed order. Queues hold each transaction at a
# known statement. Nothing here sleeps to skip the overlapping insert.
RSpec.describe 'External media GC shared-asset race' do
  self.use_transactional_tests = false

  let(:feed_url) { 'https://feeds.example/media-gc-race.xml' }
  let(:image_url) { 'https://cdn.example/gc-race.png' }
  let(:png) { Rails.root.join('spec', 'fixtures', 'files', 'emojo.png').binread }

  before do
    ActiveRecord::Base.connection_pool.lock_thread = false
    @user = Fabricate(:user)
    @other = Fabricate(:user)
    enable_external_bridge_rss!(@user, @other)
    stub_request(:get, image_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
    stub_request(:get, feed_url).to_return(status: 200, body: rss_document(item_xml), headers: { 'Content-Type' => 'application/rss+xml' })
  end

  after do
    release_thread_redis!
    cleanup!
    ActiveRecord::Base.connection_pool.lock_thread = true
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
  end

  def item_xml
    <<~XML
      <item>
        <guid>gc-race</guid>
        <title>GC Race</title>
        <link>https://example.com/gc-race</link>
        <description><![CDATA[Plain story<img src="#{image_url}" alt="Story">]]></description>
      </item>
    XML
  end

  def cleanup!
    account_ids = [@user, @other].compact.map(&:account_id)
    [@user, @other].compact.each do |user|
      ExternalBridge::DeleteUser.call(User.find(user.id)) if User.exists?(user.id)
    end
    if @attachment_ids.present?
      ExternalMediaGcIntent.where(target_type: 'media_attachment', target_id: @attachment_ids).delete_all
      ExternalMediaGcProof.where(media_attachment_id: @attachment_ids).delete_all
    end
    if @asset_id
      ExternalMediaGcIntent.where(target_type: 'external_media_asset', target_id: @asset_id).delete_all
      ExternalMediaGcAssetRecheck.where(external_media_asset_id: @asset_id).delete_all
      ExternalMediaAsset.where(id: @asset_id).find_each do |asset|
        asset.destroy!
      rescue StandardError
        nil
      end
    end
    MediaAttachment.where(account_id: account_ids).find_each do |attachment|
      attachment.destroy!
    rescue StandardError
      nil
    end
    source_ids = ExternalSource.where(canonical_key: feed_url).pluck(:id)
    ExternalResource.where(external_source_id: source_ids).delete_all
    ExternalSource.where(id: source_ids).delete_all
    Account.where(id: account_ids).destroy_all
  end

  def release_thread_redis!
    RedisConfiguration.pool.checkin
  rescue StandardError
    nil
  ensure
    Thread.current[:redis] = nil
  end

  def in_thread
    holder = {}
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        yield
      end
    rescue StandardError => e
      holder[:error] = e
    ensure
      release_thread_redis!
    end
    thread.define_singleton_method(:thread_error) { holder[:error] }
    thread
  end

  def pop_queue!(queue, label)
    Timeout.timeout(20, RuntimeError, "timed out waiting for #{label}") { queue.pop }
  end

  def intent_insert_waiting?
    sql = <<~SQL.squish
      SELECT COUNT(*)
      FROM pg_locks AS locks
      JOIN pg_stat_activity AS activity ON activity.pid = locks.pid
      WHERE locks.granted = false
        AND activity.datname = current_database()
        AND activity.query ILIKE '%external_media_gc_intents%'
    SQL
    ActiveRecord::Base.connection.select_value(sql).to_i.positive?
  end

  def wait_until_intent_insert_blocks!
    Timeout.timeout(20, RuntimeError, 'the second purge did not wait on the pending asset intent') do
      loop do
        break if intent_insert_waiting?

        Thread.pass
      end
    end
  end

  it 'releases the shared asset when the first purge retains it before the second purge commits' do
    ExternalBridge::RSS::Subscribe.new.call(user: @user, url: feed_url)
    ExternalBridge::RSS::Subscribe.new.call(user: @other, url: feed_url)
    status_a_id = ExternalStatusProjection.find_by!(user_id: @user.id).status_id
    status_b_id = ExternalStatusProjection.find_by!(user_id: @other.id).status_id
    @asset_id = ExternalMediaAsset.pick(:id)
    @attachment_ids = MediaAttachment.where(account_id: [@user.account_id, @other.account_id]).pluck(:id)
    asset_path = ExternalMediaAsset.find(@asset_id).file.path
    order = []
    a_fence = Queue.new
    b_fence = Queue.new
    release_a = Queue.new
    release_b = Queue.new
    release_a_hook = Queue.new
    thread_a = nil
    thread_b = nil

    allow(ExternalBridge::MediaGc).to receive(:schedule_release!).and_wrap_original do |method, **kwargs|
      method.call(**kwargs)
      case Thread.current[:gc_actor]
      when :a
        a_fence << :a
        release_a.pop
      when :b
        b_fence << :b
        release_b.pop
      end
    end
    allow_any_instance_of(ExternalBridge::MediaGc::CommitHook).to receive(:committed!).and_wrap_original do |method, **kwargs|
      if kwargs[:should_run_callbacks] != false
        case Thread.current[:gc_actor]
        when :a
          order << :a_committed
          release_a_hook.pop
        when :b
          order << :b_committed
        end
      end
      method.call(**kwargs)
    end

    begin
      thread_a = in_thread do
        Thread.current[:gc_actor] = :a
        ExternalBridge::ProjectionPurge.purge_status!(Status.find(status_a_id))
      end
      pop_queue!(a_fence, 'A pre-commit fence')
      expect(Status.unscoped.exists?(status_a_id)).to be true
      expect(ExternalMediaGcIntent.where(target_type: 'external_media_asset', target_id: @asset_id)).to be_empty

      thread_b = in_thread do
        Thread.current[:gc_actor] = :b
        ExternalBridge::ProjectionPurge.purge_status!(Status.find(status_b_id))
      end
      wait_until_intent_insert_blocks!
      expect(b_fence).to be_empty
      expect(order).to eq []

      release_a << :go
      pop_queue!(b_fence, 'B pre-commit fence')
      expect(order).to eq [:a_committed]
      expect(Status.unscoped.exists?(status_a_id)).to be false
      expect(Status.unscoped.exists?(status_b_id)).to be true
      expect(ExternalMediaAsset.exists?(@asset_id)).to be true

      release_a_hook << :go
      Timeout.timeout(20) { thread_a.join }
      raise thread_a.thread_error if thread_a.thread_error

      retained = ExternalMediaGcIntent.find_by!(target_type: 'external_media_asset', target_id: @asset_id)
      expect(retained.state).to eq 'retained'
      expect(retained.last_error_code).to eq 'still_referenced'
      expect(ExternalMediaGcIntent.pending.where(target_type: 'external_media_asset', target_id: @asset_id)).to be_empty
      expect(Status.unscoped.exists?(status_b_id)).to be true
      expect(File.exist?(asset_path)).to be true
      expect(order).to eq [:a_committed]

      release_b << :go
      Timeout.timeout(20) { thread_b.join }
      raise thread_b.thread_error if thread_b.thread_error

      successor = ExternalMediaGcIntent.where(target_type: 'external_media_asset', target_id: @asset_id).order(:id).last
      expect(order).to eq [:a_committed, :b_committed]
      expect(successor.id).to be > retained.id
      expect(successor.created_at).to be >= retained.resolved_at
      expect(successor.state).to eq 'released'
      expect(Status.unscoped.exists?(status_b_id)).to be false
      expect(ExternalMediaAsset.where(id: @asset_id)).to be_empty
      expect(File.exist?(asset_path)).to be false
    ensure
      release_a << :go
      release_a_hook << :go
      release_b << :go
      thread_a&.join(5)
      thread_b&.join(5)
    end
  end
end
