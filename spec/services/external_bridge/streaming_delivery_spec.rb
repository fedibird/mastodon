# frozen_string_literal: true

require 'rails_helper'

describe 'ExternalBridge streaming delivery' do
  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  before do
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ExternalBridge::StreamDeleteWorker.clear
  end

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
    Setting.external_bridge_external_visibility = false
  end

  def published
    @published ||= []
  end

  def stub_publish!
    @published = []
    allow_any_instance_of(ExternalBridge::Streaming::Publisher).to receive(:publish) do |_publisher, channel, event, payload, delivery: nil|
      published << { channel: channel, event: event.to_s, payload: payload, delivery: delivery }
      true
    end
  end

  def permit!(*users)
    Setting.external_bridge_external_visibility = true
    enable_external_bridge_feeds!(*users)
    enable_external_bridge_rss!(*users)
  end

  def save_routes(user, subscription, home:, list_ids:)
    ExternalBridge::FeedRoutes::Update.new.call(
      user: user,
      subscription_id: subscription.id,
      home: home,
      list_ids: list_ids,
      expected_revision: subscription.reload.feed_routes_revision
    )
  end

  def source_bundle(user)
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml",
      title: 'Public feed',
      site_url: 'https://example.com',
      etag: 'W/"public"',
      fetched_at: Time.current,
      checked_at: Time.current
    )
    resource = ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: "feed:#{source.canonical_key}\nitem:guid-1",
      title: 'Imported title',
      body: 'Secret article body',
      canonical_url: 'https://example.com/posts/1',
      byline: 'Ada',
      revision: 'rev-1',
      published_at: Time.utc(2020, 1, 2, 3, 4, 5)
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    { source: source, resource: resource, subscription: subscription }
  end

  def write_projection!(user, bundle, text: 'Secret article body')
    ExternalBridge::ProjectionWriter.new.create!(
      user: user,
      subscription: bundle[:subscription],
      resource: bundle[:resource],
      text: text
    )
  end

  def perform_content(index = 0)
    job = ExternalBridge::StreamContentWorker.jobs.fetch(index)
    ExternalBridge::StreamContentWorker.new.perform(*job['args'])
  end

  def perform_control(index = 0)
    job = ExternalBridge::StreamControlWorker.jobs.fetch(index)
    ExternalBridge::StreamControlWorker.new.perform(*job['args'])
  end

  def perform_delete(index = 0)
    job = ExternalBridge::StreamDeleteWorker.jobs.fetch(index)
    ExternalBridge::StreamDeleteWorker.new.perform(*job['args'])
  end

  def payload_id(entry)
    body = entry[:payload]
    body.is_a?(Hash) ? (body['id'] || body[:id]).to_s : body.to_s
  end

  def payload_text(entry)
    body = entry[:payload]
    return '' unless body.is_a?(Hash)

    (body['content'] || body[:content]).to_s
  end

  def during_render(status)
    entered = false
    allow(ExternalBridge::Streaming::StatusRenderer).to receive(:render).and_wrap_original do |method, rendered_status, rendered_user|
      body = method.call(rendered_status, rendered_user)
      if !entered && rendered_status.id == status.id
        entered = true
        yield
      end
      body
    end
  end

  it 'enqueues a content job only after the outer transaction commits' do
    user = Fabricate(:user)
    permit!(user)
    bundle = source_bundle(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamControlWorker.clear

    ApplicationRecord.transaction do
      ApplicationRecord.transaction(requires_new: true) do
        write_projection!(user, bundle)
      end
      expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    end

    expect(ExternalBridge::StreamContentWorker.jobs.size).to eq 1
    args = ExternalBridge::StreamContentWorker.jobs.first['args']
    expect(args).to all(be_a(String))
    expect(args.join(' ')).not_to include('Secret article body')
    expect(args.join(' ')).not_to include('http')
  end

  it 'does not enqueue when the outer transaction rolls back' do
    user = Fabricate(:user)
    permit!(user)
    bundle = source_bundle(user)

    ApplicationRecord.transaction do
      ApplicationRecord.transaction(requires_new: true) do
        write_projection!(user, bundle)
      end
      expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
      raise ActiveRecord::Rollback
    end

    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(ExternalStatusProjection.where(user_id: user.id)).to be_empty
  end

  it 'does not enqueue when the savepoint itself rolls back' do
    user = Fabricate(:user)
    permit!(user)
    bundle = source_bundle(user)

    ApplicationRecord.transaction do
      write_projection!(user, bundle)
      raise ActiveRecord::Rollback
    end

    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(Status.where(account_id: user.account_id, external_projection: true)).to be_empty
  end

  it 'publishes one update on the owner home channel and keeps the id a string' do
    user = Fabricate(:user)
    roommate = share_account_user(user.account)
    other = Fabricate(:user)
    permit!(user, roommate, other)
    bundle = source_bundle(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamControlWorker.clear
    _status, marker = write_projection!(user, bundle)
    stub_publish!
    expect { perform_content }.not_to change { Notification.count }

    expect(published.map { |entry| entry[:event] }).to eq ['update']
    expect(published.map { |entry| entry[:channel] }).to eq [ExternalBridge::Streaming::Channels.home(user.id)]
    expect(published.map { |entry| entry[:channel] }).not_to include("timeline:#{user.account_id}")
    expect(published.map { |entry| entry[:channel] }).not_to include(ExternalBridge::Streaming::Channels.home(roommate.id))
    expect(published.map { |entry| entry[:channel] }).not_to include(ExternalBridge::Streaming::Channels.home(other.id))
    expect(payload_id(published.first)).to eq marker.status_id.to_s
    expect(payload_id(published.first)).to be_a(String)
    body = published.first[:payload]
    expect(body).not_to have_key('_fedibird_searchable_text')
    expect(body).not_to have_key(:_fedibird_searchable_text)
    expect(marker.reload.streamed_content_generation).to eq 1
    expect(marker.content_generation).to eq 1
  end

  it 'publishes home and list channels once each for the same status id' do
    user = Fabricate(:user)
    permit!(user)
    list = Fabricate(:list, account: user.account)
    other_list = Fabricate(:list, account: user.account)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [list.id])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    stub_publish!
    perform_content

    channels = published.map { |entry| entry[:channel] }
    expect(channels).to contain_exactly(
      ExternalBridge::Streaming::Channels.home(user.id),
      ExternalBridge::Streaming::Channels.list(user.id, list.id)
    )
    expect(channels).not_to include(ExternalBridge::Streaming::Channels.list(user.id, other_list.id))
    expect(published.map { |entry| payload_id(entry) }.uniq).to eq [bundle[:status].id.to_s]
    route_ids = published.map { |entry| entry[:delivery]['route_id'] }
    expect(route_ids).to contain_exactly(
      ExternalFeedRoute.find_by!(user_id: user.id, external_subscription_id: bundle[:subscription].id, destination: 'home').id.to_s,
      ExternalFeedRoute.find_by!(user_id: user.id, external_subscription_id: bundle[:subscription].id, destination: 'list', list_id: list.id).id.to_s
    )
    expect(published).to all(satisfy { |entry| !entry[:payload].key?('route_id') })
  end

  it 'publishes a list-only status on that list channel' do
    user = Fabricate(:user)
    permit!(user)
    list = Fabricate(:list, account: user.account)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: false, list_ids: [list.id])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    stub_publish!
    perform_content

    expect(published.map { |entry| entry[:channel] }).to eq [ExternalBridge::Streaming::Channels.list(user.id, list.id)]
  end

  it 'does not publish or mark streamed when the user has no route' do
    user = Fabricate(:user)
    permit!(user)
    bundle = source_bundle(user)
    _status, marker = write_projection!(user, bundle)
    stub_publish!
    perform_content

    expect(published).to be_empty
    expect(marker.reload.streamed_content_generation).to be_nil
    expect(marker.content_generation).to eq 1
  end

  it 'does not enqueue when the delivery flag or the tester list excludes the owner' do
    user = Fabricate(:user)
    Setting.external_bridge_external_visibility = true
    bundle = source_bundle(user)
    write_projection!(user, bundle)
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty

    enable_external_bridge_feeds!(Fabricate(:user))
    bundle = source_bundle(user)
    write_projection!(user, bundle)
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(Status.where(account_id: user.account_id, external_projection: true).count).to eq 2
  end

  it 'does not enqueue a legacy personal projection' do
    user = Fabricate(:user)
    enable_external_bridge_feeds!(user)
    bundle = source_bundle(user)
    write_projection!(user, bundle)
    status = Status.where(account_id: user.account_id, external_projection: true).order(:id).last

    expect(status.personal_visibility?).to be true
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
  end

  it 'drops a job when the user is no longer functional or the flag is off' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    user.account.update!(suspended_at: Time.current)
    stub_publish!
    perform_content
    expect(published).to be_empty

    user.account.update!(suspended_at: nil)
    Setting.external_bridge_feeds = false
    perform_content
    expect(published).to be_empty
    expect(bundle[:marker].reload.streamed_content_generation).to be_nil
  end

  it 'sends the current text when a newer generation runs before an older one' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'old text')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    bundle[:status].update_columns(text: 'first body')
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    bundle[:status].update_columns(text: 'second body')
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    stub_publish!
    perform_content(1)
    perform_content(0)

    expect(published.map { |entry| entry[:event] }).to eq ['update']
    expect(payload_text(published.first)).to include('second body')
    expect(payload_text(published.first)).not_to include('first body')
    expect(bundle[:marker].reload.streamed_content_generation).to eq 2
  end

  it 'drops a rendered older body when a newer generation finishes during render' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'old text')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    bundle[:status].update_columns(text: 'first body')
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    older = ExternalBridge::StreamContentWorker.jobs.first['args']
    stub_publish!
    during_render(bundle[:status]) do
      bundle[:status].update_columns(text: 'second body')
      bundle[:marker].update_columns(content_generation: 2)
      ExternalBridge::StreamContentWorker.new.perform(
        user.id.to_s,
        bundle[:marker].id.to_s,
        bundle[:status].id.to_s,
        bundle[:subscription].id.to_s,
        '2'
      )
    end
    ExternalBridge::StreamContentWorker.new.perform(*older)

    expect(published.map { |entry| entry[:event] }).to eq ['update']
    expect(payload_text(published.first)).to include('second body')
    expect(payload_text(published.first)).not_to include('first body')
    expect(published.first[:delivery]['generation']).to eq '2'
    expect(published.first[:payload]).not_to have_key('delivery')
    expect(bundle[:marker].reload.streamed_content_generation).to eq 2
  end

  it 'drops a rendered body when purge finishes during render' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'do not return')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    older = ExternalBridge::StreamContentWorker.jobs.first['args']
    stub_publish!
    during_render(bundle[:status]) do
      ExternalBridge::ProjectionPurge.purge_status!(bundle[:status])
      perform_delete
    end
    ExternalBridge::StreamContentWorker.new.perform(*older)

    expect(published.map { |entry| entry[:event] }).to eq ['delete']
    expect(published.first[:payload]).to eq bundle[:status].id.to_s
    expect(published.first[:delivery]).to eq(
      'kind' => 'delete',
      'user_id' => user.id.to_s,
      'status_id' => bundle[:status].id.to_s
    )
    expect(Status.exists?(bundle[:status].id)).to be false
  end

  it 'drops a rendered body when the route is removed during render' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'do not return')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    older = ExternalBridge::StreamContentWorker.jobs.first['args']
    stub_publish!
    during_render(bundle[:status]) do
      save_routes(user, bundle[:subscription], home: false, list_ids: [])
      perform_control
    end
    ExternalBridge::StreamContentWorker.new.perform(*older)

    expect(published.map { |entry| entry[:event] }).to eq ['external_feed_changed']
    expect(published.first[:payload]['reason']).to eq 'routes_updated'
    expect(bundle[:marker].reload.streamed_content_generation).to be_nil
    expect(Status.exists?(bundle[:status].id)).to be true
  end

  it 'drops a rendered body when source_deleted is saved during render' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'do not return')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    older = ExternalBridge::StreamContentWorker.jobs.first['args']
    subscription = bundle[:subscription].reload
    stub_publish!
    during_render(bundle[:status]) do
      bundle[:marker].update!(source_deleted: true)
      control = {
        'version' => 1,
        'reason' => 'source_deleted',
        'targets' => [{ 'type' => 'home' }],
        'subscription_id' => subscription.id.to_s,
        'feed_routes_revision' => subscription.feed_routes_revision.to_s,
        'status_id' => bundle[:status].id.to_s,
      }
      ExternalBridge::StreamControlWorker.new.perform(user.id.to_s, control)
    end
    ExternalBridge::StreamContentWorker.new.perform(*older)

    expect(published.map { |entry| entry[:event] }).to eq ['external_feed_changed']
    expect(published.first[:payload]['reason']).to eq 'source_deleted'
    expect(bundle[:marker].reload.streamed_content_generation).to be_nil
    expect(bundle[:marker].source_deleted).to be true
    expect(Status.exists?(bundle[:status].id)).to be true
  end

  it 'sends update and then status.update in commit order' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'old text')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    bundle[:status].update_columns(text: 'first body')
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    stub_publish!
    perform_content(0)
    bundle[:status].update_columns(text: 'second body')
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    perform_content(1)

    expect(published.map { |entry| entry[:event] }).to eq ['update', 'status.update']
    expect(payload_text(published.last)).to include('second body')
    expect(bundle[:marker].reload.streamed_content_generation).to eq 2
  end

  it 'treats an update that arrives before the first publish as the inserting update' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'current body')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    bundle[:marker].update_columns(content_generation: 2)
    args = [
      user.id.to_s,
      bundle[:marker].id.to_s,
      bundle[:status].id.to_s,
      bundle[:subscription].id.to_s,
    ]
    ExternalBridge::StreamContentWorker.perform_async(*(args + ['1']))
    ExternalBridge::StreamContentWorker.perform_async(*(args + ['2']))
    stub_publish!
    perform_content(1)
    perform_content(0)

    expect(published.map { |entry| entry[:event] }).to eq ['update']
    expect(payload_text(published.first)).to include('current body')
    expect(bundle[:marker].reload.streamed_content_generation).to eq 2
  end

  it 'does not replay a skipped event after the flag is turned on' do
    user = Fabricate(:user)
    Setting.external_bridge_external_visibility = true
    bundle = source_bundle(user)
    write_projection!(user, bundle)
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty

    enable_external_bridge_feeds!(user)
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
  end

  it 'keeps a failed publish unmarked and logs only ids and the error class' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'Secret article body')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    allow_any_instance_of(ExternalBridge::Streaming::Publisher).to receive(:publish).and_raise(Redis::CommandError, 'NOAUTH secret-token-value')
    expect(Rails.logger).to receive(:warn) do |line|
      expect(line).to include('error=Redis::CommandError')
      expect(line).not_to include('secret-token-value')
      expect(line).not_to include('Secret article body')
      expect(line).not_to include('https://')
    end

    expect { perform_content }.to raise_error(Redis::CommandError)
    expect(bundle[:marker].reload.streamed_content_generation).to be_nil
  end

  it 'retries a content publish that failed and then marks streamed' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'retry body')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    attempts = 0
    allow_any_instance_of(ExternalBridge::Streaming::Publisher).to receive(:publish) do |_publisher, _channel, event, payload, delivery: nil|
      attempts += 1
      raise Redis::CommandError, 'NOAUTH' if attempts == 1

      published << { event: event.to_s, payload: payload, delivery: delivery }
      true
    end

    expect { perform_content }.to raise_error(Redis::CommandError)
    expect(bundle[:marker].reload.streamed_content_generation).to be_nil
    perform_content
    expect(published.map { |entry| entry[:event] }).to eq ['update']
    expect(payload_text(published.first)).to include('retry body')
    expect(bundle[:marker].reload.streamed_content_generation).to eq 1
  end

  it 'uses the explicit owner and does not borrow Account#user' do
    user = Fabricate(:user)
    roommate = share_account_user(user.account)
    permit!(user, roommate)
    bundle = external_project_for(user)
    Favourite.create!(account: user.account, status: bundle[:status])
    allow(user.account).to receive(:user).and_return(roommate)

    borrowed = InlineRenderer.render(bundle[:status], user.account, :status)
    borrowed_external = borrowed['fedibird_external'] || borrowed[:fedibird_external]
    explicit = ExternalBridge::Streaming::StatusRenderer.render(bundle[:status], user)
    explicit_external = explicit['fedibird_external'] || explicit[:fedibird_external]
    favourited = explicit['favourited']
    favourited = explicit[:favourited] if favourited.nil?

    expect(borrowed_external).to be_nil
    interaction = explicit_external[:interaction] || explicit_external['interaction']
    canonical = explicit_external[:canonical_url] || explicit_external['canonical_url']
    expect(interaction).to eq 'local_only'
    expect(canonical).to eq 'https://example.com/posts/external'
    expect(favourited).to be true
    expect(ExternalBridge::Streaming::StatusRenderer.render(bundle[:status], roommate)).to be_nil
  end

  it 'keeps a normal status render on InlineRenderer' do
    status = Fabricate(:status, text: 'ordinary note')
    rendered = InlineRenderer.render(status, status.account, :status)
    rendered_id = rendered['id'] || rendered[:id]

    expect(rendered_id).to eq status.id.to_s
    expect(rendered).not_to have_key('fedibird_external')
    expect(rendered).not_to have_key(:fedibird_external)
  end

  it 'leaves PushUpdateWorker unwilling to publish a private projection' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)
    worker = PushUpdateWorker.new
    expect(worker).not_to receive(:redis)

    expect(worker.perform(user.account_id, bundle[:status].id, "timeline:#{user.account_id}")).to be true
  end

  it 'publishes a real Redis message for one private update' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'redis body')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    channel = ExternalBridge::Streaming::Channels.home(user.id)
    ready = Queue.new
    received = Queue.new
    thread = Thread.new do
      RedisConfiguration.with do |redis|
        redis.subscribe(channel) do |on|
          on.subscribe { ready << true }
          on.message { |_subscribed, message| received << message }
        end
      end
    end
    expect(ready.pop(timeout: 3)).to be true
    perform_content
    raw = received.pop(timeout: 3)
    parsed = Oj.load(raw)

    expect(parsed['event']).to eq 'update'
    expect(parsed['payload']['id']).to eq bundle[:status].id.to_s
    expect(parsed['payload']['id']).to be_a(String)
    expect(parsed['delivery']['kind']).to eq 'content'
    expect(parsed['delivery']['generation']).to eq bundle[:marker].reload.content_generation.to_s
    expect(parsed['delivery']['route_id']).to eq ExternalFeedRoute.find_by!(user_id: user.id, external_subscription_id: bundle[:subscription].id, destination: 'home').id.to_s
    expect(parsed['payload']).not_to have_key('delivery')
    expect(parsed['payload']).not_to have_key('generation')
    expect(parsed['payload']).not_to have_key('route_id')
  ensure
    thread&.kill
    thread&.join(1)
  end

  it 'keeps a huge status id as a decimal string in the payload' do
    user = Fabricate(:user)
    permit!(user)
    huge = 9_007_199_254_740_993
    bundle = external_project_for(user, id: huge)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    stub_publish!
    perform_content

    expect(payload_id(published.first)).to eq '9007199254740993'
    expect(published.first[:payload]['id'] || published.first[:payload][:id]).to be_a(String)
  end

  it 'does not emit a content event for the same revision, checked_at, or a failed body save' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    text = ExternalBridge::RSS::Excerpt.for(bundle[:resource])
    bundle[:status].update_columns(text: text)
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    bundle[:source].update!(checked_at: Time.current)

    result = ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription], resources: [bundle[:resource]])

    expect(result.succeeded).to eq 1
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(ExternalBridge::StreamControlWorker.jobs).to be_empty
    expect(bundle[:marker].reload.content_generation).to eq 0

    bundle[:resource].update!(title: 'Changed title', revision: 'rev-2')
    status = bundle[:status]
    allow_any_instance_of(Status).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(status))
    failed = ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription], resources: [bundle[:resource].reload])

    expect(failed.failed).to eq 1
    expect(bundle[:marker].reload.last_seen_revision).to eq 'rev-external'
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
  end

  it 'sends source_deleted and source_restored as control events' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    text = ExternalBridge::RSS::Excerpt.for(bundle[:resource])
    bundle[:status].update_columns(text: text)
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    bundle[:resource].update!(title: 'Gone title', revision: 'rev-deleted', source_deleted_at: Time.current)

    ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription], resources: [bundle[:resource].reload])

    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
    expect(ExternalBridge::StreamControlWorker.jobs.size).to eq 1
    payload = ExternalBridge::StreamControlWorker.jobs.first['args'].last
    expect(payload['reason']).to eq 'source_deleted'
    expect(payload['status_id']).to eq bundle[:status].id.to_s
    expect(payload.keys).not_to include('content', 'text', 'url', 'canonical_url')
    expect(Status.exists?(bundle[:status].id)).to be true
    stub_publish!
    perform_control
    expect(published.map { |entry| entry[:channel] }).to eq [ExternalBridge::Streaming::Channels.control(user.id)]
    expect(published.first[:event]).to eq 'external_feed_changed'

    ExternalBridge::StreamControlWorker.clear
    published.clear
    bundle[:resource].update!(source_deleted_at: nil, revision: 'rev-back')
    ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription], resources: [bundle[:resource].reload])
    restored = ExternalBridge::StreamControlWorker.jobs.first['args'].last
    expect(restored['reason']).to eq 'source_restored'
    expect(restored['status_id']).to eq bundle[:status].id.to_s
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
  end

  it 'asks every changed destination to reload and ignores a no-op' do
    user = Fabricate(:user)
    permit!(user)
    list = Fabricate(:list, account: user.account)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [list.id])
    revision = bundle[:subscription].reload.feed_routes_revision
    ExternalBridge::StreamControlWorker.clear
    save_routes(user, bundle[:subscription], home: true, list_ids: [list.id])

    expect(bundle[:subscription].reload.feed_routes_revision).to eq revision
    expect(ExternalBridge::StreamControlWorker.jobs).to be_empty

    home_route_id = ExternalFeedRoute.find_by!(user_id: user.id, external_subscription_id: bundle[:subscription].id, destination: 'home').id.to_s
    list_route_id = ExternalFeedRoute.find_by!(user_id: user.id, external_subscription_id: bundle[:subscription].id, destination: 'list', list_id: list.id).id.to_s
    save_routes(user, bundle[:subscription], home: false, list_ids: [])
    removal = ExternalBridge::StreamControlWorker.jobs.last['args']
    payload = removal[1]
    expect(payload['reason']).to eq 'routes_updated'
    expect(payload['targets']).to include({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
    expect(payload.keys).not_to include('route_id', 'removed_route_id', 'epochs')
    expect(removal[2]).to eq(
      'kind' => 'routes',
      'subscription_id' => bundle[:subscription].id.to_s,
      'epochs' => [
        { 'type' => 'home', 'removed_route_id' => home_route_id },
        { 'type' => 'list', 'id' => list.id.to_s, 'removed_route_id' => list_route_id },
      ]
    )
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty

    ExternalBridge::StreamControlWorker.clear
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(ExternalBridge::StreamControlWorker.jobs.size).to eq 1
    added = ExternalBridge::StreamControlWorker.jobs.last['args']
    expect(added[1].keys).not_to include('route_id', 'removed_route_id', 'epochs')
    added_id = ExternalFeedRoute.find_by!(user_id: user.id, external_subscription_id: bundle[:subscription].id, destination: 'home').id.to_s
    expect(added_id).not_to eq home_route_id
    expect(added[2]['epochs']).to eq [{ 'type' => 'home', 'route_id' => added_id }]
  end

  it 'bumps the revision when a list is deleted and emits list_removed' do
    user = Fabricate(:user)
    permit!(user)
    list = Fabricate(:list, account: user.account)
    other = Fabricate(:list, account: user.account)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [list.id, other.id])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear

    Favourite.create!(account: user.account, status: bundle[:status])
    Bookmark.create!(account: user.account, status: bundle[:status])
    roommate = share_account_user(user.account)
    permit!(roommate)

    list.destroy!

    payload = ExternalBridge::StreamControlWorker.jobs.last['args'].last
    expect(payload['reason']).to eq 'list_removed'
    expect(payload['targets']).to eq [{ 'type' => 'list', 'id' => list.id.to_s }]
    expect(payload.keys).not_to include('content', 'text', 'url', 'canonical_url')
    expect(ExternalBridge::StreamControlWorker.jobs.map { |job| job['args'].first }).to eq [user.id.to_s]
    expect(bundle[:subscription].reload.feed_routes_revision).to be > 1
    expect(Status.exists?(bundle[:status].id)).to be true
    expect(Favourite.where(account_id: user.account_id, status_id: bundle[:status].id)).to exist
    expect(Bookmark.where(account_id: user.account_id, status_id: bundle[:status].id)).to exist
    expect(ExternalBridge::StreamContentWorker.jobs).to be_empty
    expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
    expect(ExternalFeedRoute.where(list_id: other.id)).to exist
  end

  it 'advances the revision without an event when delivery is off and a list is deleted' do
    user = Fabricate(:user)
    list = Fabricate(:list, account: user.account)
    bundle = external_project_for(user)
    enable_external_bridge_feeds!(user)
    save_routes(user, bundle[:subscription], home: false, list_ids: [list.id])
    Setting.external_bridge_feeds = false
    revision = bundle[:subscription].reload.feed_routes_revision
    ExternalBridge::StreamControlWorker.clear

    list.destroy!

    expect(bundle[:subscription].reload.feed_routes_revision).to eq revision + 1
    expect(ExternalBridge::StreamControlWorker.jobs).to be_empty
  end

  it 'rejects a future control revision and still sends an older one' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    subscription = bundle[:subscription].reload
    stub_publish!
    current = subscription.feed_routes_revision.to_s
    base = {
      'version' => 1,
      'reason' => 'routes_updated',
      'targets' => [{ 'type' => 'home' }],
      'subscription_id' => subscription.id.to_s,
    }
    ExternalBridge::StreamControlWorker.new.perform(user.id.to_s, base.merge('feed_routes_revision' => (subscription.feed_routes_revision + 5).to_s))
    expect(published).to be_empty

    ExternalBridge::StreamControlWorker.new.perform(user.id.to_s, base.merge('feed_routes_revision' => current))
    expect(published.size).to eq 1
    expect(published.first[:channel]).to eq ExternalBridge::Streaming::Channels.control(user.id)
  end

  it 'sends subscription_removed once the unsubscribe is accepted, and the delete events follow from the job' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    subscription = bundle[:subscription].reload
    payload = {
      'version' => 1,
      'reason' => 'subscription_removed',
      'targets' => [{ 'type' => 'home' }],
      'subscription_id' => subscription.id.to_s,
      'feed_routes_revision' => subscription.feed_routes_revision.to_s,
    }
    stub_publish!
    ExternalBridge::StreamControlWorker.new.perform(user.id.to_s, payload)
    expect(published).to be_empty

    ExternalBridge::StreamControlWorker.clear
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: user, subscription_id: subscription.id)
    control_job = ExternalBridge::StreamControlWorker.jobs.last
    expect(subscription.reload.state).to eq 'deleting'
    expect(Status.exists?(bundle[:status].id)).to be true
    stub_publish!
    ExternalBridge::StreamControlWorker.new.perform(*control_job['args'])
    expect(published.map { |entry| entry[:event] }).to eq ['external_feed_changed']
    expect(published.first[:payload]['reason']).to eq 'subscription_removed'

    ExternalBridge::RSS::SubscriptionDeletionWorker.drain
    delete_job = ExternalBridge::StreamDeleteWorker.jobs.last
    stub_publish!
    ExternalBridge::StreamDeleteWorker.new.perform(*delete_job['args'])

    expect(published.map { |entry| entry[:event] }).to eq ['delete']
    expect(published.first[:channel]).to eq ExternalBridge::Streaming::Channels.home(user.id)
    expect(published.first[:payload]).to eq bundle[:status].id.to_s
    expect(Status.exists?(bundle[:status].id)).to be false
    expect(ExternalSubscription.exists?(subscription.id)).to be false
  end

  it 'does not let a content job resurrect a purged status' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user, body: 'do not resurrect')
    save_routes(user, bundle[:subscription], home: true, list_ids: [])
    ExternalBridge::StreamContentWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.bump_and_schedule_content!(bundle[:marker].reload)
    end
    content_job = ExternalBridge::StreamContentWorker.jobs.first
    ExternalBridge::ProjectionPurge.purge_status!(bundle[:status])
    stub_publish!
    ExternalBridge::StreamContentWorker.new.perform(*content_job['args'])
    expect(published).to be_empty

    perform_delete
    expect(published.map { |entry| entry[:event] }).to eq ['delete']
    expect(published.first[:payload]).to eq bundle[:status].id.to_s
    expect(published.first[:channel]).to eq ExternalBridge::Streaming::Channels.home(user.id)
  end

  it 'does not publish a delete for a status that still exists' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)
    stub_publish!
    ExternalBridge::StreamDeleteWorker.new.perform([
      {
        'user_id' => user.id.to_s,
        'status_id' => bundle[:status].id.to_s,
        'subscription_id' => bundle[:subscription].id.to_s,
        'destinations' => [{ 'type' => 'home' }],
      },
    ])

    expect(published).to be_empty
  end

  it 'does not enqueue streaming deletes when the user record is being removed' do
    user = Fabricate(:user)
    permit!(user)
    external_project_for(user)
    ExternalBridge::StreamDeleteWorker.clear

    ExternalBridge::DeleteUser.call(user)

    expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
    expect(User.where(id: user.id)).to be_empty
  end

  it 'does not enqueue a purge that the outer transaction rolls back' do
    user = Fabricate(:user)
    permit!(user)
    bundle = external_project_for(user)

    ApplicationRecord.transaction do
      ApplicationRecord.transaction(requires_new: true) do
        ExternalBridge::ProjectionPurge.purge_status!(bundle[:status])
      end
      expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
      raise ActiveRecord::Rollback
    end

    expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
    expect(Status.exists?(bundle[:status].id)).to be true
  end

  it 'batches captured deletes and does not store the status body' do
    captures = Array.new(101) do |index|
      {
        'user_id' => '15',
        'status_id' => (index + 1).to_s,
        'subscription_id' => '9',
        'destinations' => [{ 'type' => 'home' }],
        'text' => 'secret body',
        'url' => 'https://secret.example/post',
      }
    end

    ApplicationRecord.transaction do
      ExternalBridge::Streaming::Scheduler.schedule_deletes!(captures)
    end

    expect(ExternalBridge::StreamDeleteWorker.jobs.size).to eq 2
    first = ExternalBridge::StreamDeleteWorker.jobs.first['args'].first
    second = ExternalBridge::StreamDeleteWorker.jobs.second['args'].first
    expect(first.size).to eq 100
    expect(second.size).to eq 1
    expect(first.first.keys).to contain_exactly('user_id', 'status_id', 'subscription_id', 'destinations')
    expect(first.first.to_s).not_to include('secret')
  end

  it 'no-ops a content job whose marker is missing' do
    user = Fabricate(:user)
    permit!(user)
    stub_publish!
    ExternalBridge::StreamContentWorker.new.perform(user.id.to_s, '99', '98', '97', '1')

    expect(published).to be_empty
  end
end
