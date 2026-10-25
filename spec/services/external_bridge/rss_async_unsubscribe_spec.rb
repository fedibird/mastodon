# frozen_string_literal: true

# Asynchronous unsubscribe (issue #575): accept + fence, batched physical
# purge, resume, recovery, and the writers that must not get past the fence.
# One world builder is shared, so the contract stays in one file.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe 'ExternalBridge asynchronous RSS unsubscribe', type: :model do
  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  let(:user) { Fabricate(:user) }
  let(:runner) { ExternalBridge::RSS::SubscriptionDeletionRunner.new }
  let(:scheduler) { Scheduler::ExternalBridgeRSSSubscriptionDeletionScheduler.new }

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    ExternalBridge::RSS::SubscriptionDeletionWorker.clear
    ExternalBridge::StreamControlWorker.clear
    ExternalBridge::StreamDeleteWorker.clear
    enable_external_bridge_rss!(user)
  end

  after do
    Setting.external_bridge_rss = false
    Setting.external_bridge_rss_testers = ''
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
  end

  def add_projections(world, count, owner: user)
    Array.new(count) do |index|
      resource = ExternalResource.create!(
        external_source: world[:source],
        protocol: 'rss',
        canonical_key: "feed:#{world[:source].canonical_key}\nitem:extra-#{SecureRandom.hex(4)}-#{index}",
        title: "Extra #{index}",
        body: 'Extra body',
        canonical_url: "https://example.com/posts/extra-#{index}",
        revision: 'rev-extra',
        published_at: Time.utc(2020, 1, 2, 3, 4, 5)
      )
      status, = ExternalBridge::ProjectionWriter.new.create!(
        user: owner, subscription: world[:subscription], resource: resource, text: 'Extra body'
      )
      status
    end
  end

  def world_with(count)
    world = project_for(user)
    add_projections(world, count - 1) if count > 1
    world
  end

  def unsubscribe!(world, who: user)
    ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: who, subscription_id: world[:subscription].id)
  end

  def projection_count(world)
    ExternalStatusProjection.where(external_subscription_id: world[:subscription].id).count
  end

  def save_routes(world, home:, list_ids: [])
    Setting.external_bridge_feeds = true
    enable_external_bridge_feeds!(user)
    ExternalBridge::FeedRoutes::Update.new.call(
      user: user,
      subscription_id: world[:subscription].id,
      home: home,
      list_ids: list_ids,
      expected_revision: world[:subscription].reload.feed_routes_revision
    )
  end

  def error_code(code)
    raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq(code) }
  end

  describe 'accepting the request' do
    it 'fences the subscription, records the job, and deletes nothing yet' do
      world = world_with(3)
      list = Fabricate(:list, account: user.account)
      save_routes(world, home: true, list_ids: [list.id])
      ExternalBridge::StreamControlWorker.clear
      ordinary = Fabricate(:status, account: user.account, text: 'plain personal post')

      deletion = unsubscribe!(world)

      expect(deletion).to be_queued
      expect(deletion.user_id).to eq user.id
      expect(deletion.external_subscription_id).to eq world[:subscription].id
      expect(deletion.total_count).to be_nil
      expect(deletion.route_targets).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      expect(world[:subscription].reload.state).to eq 'deleting'
      expect(ExternalFeedRoute.where(external_subscription_id: world[:subscription].id)).to be_empty
      expect(projection_count(world)).to eq 3
      expect(Status.where(id: ExternalStatusProjection.where(external_subscription_id: world[:subscription].id).select(:status_id)).count).to eq 3
      expect(Status.exists?(ordinary.id)).to be true
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.first['args']).to eq [deletion.id]
      expect(ExternalBridge::StreamControlWorker.jobs.size).to eq 1
      payload = ExternalBridge::StreamControlWorker.jobs.first['args'].second
      expect(payload['reason']).to eq 'subscription_removed'
      expect(payload['targets']).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
    end

    it 'returns the same record for a repeated request and pushes one job' do
      world = world_with(2)

      first = unsubscribe!(world)
      second = unsubscribe!(world)

      expect(second.id).to eq first.id
      expect(ExternalSubscriptionDeletion.where(external_subscription_id: world[:subscription].id).count).to eq 1
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
    end

    it 'returns the finished record for a request after completion and keeps the ids private' do
      world = world_with(1)
      first = unsubscribe!(world)
      runner.call(first.id)
      expect(ExternalSubscription.exists?(world[:subscription].id)).to be false

      again = unsubscribe!(world)

      expect(again.id).to eq first.id
      expect(again).to be_completed
      stranger = Fabricate(:user)
      expect { unsubscribe!(world, who: stranger) }.to error_code('not_found')
      roommate = share_account_user(user.account)
      expect { unsubscribe!(world, who: roommate) }.to error_code('not_found')
      expect { ExternalBridge::RSS::Subscribe.new.unsubscribe!(user: user, subscription_id: 'abc') }.to error_code('not_found')
    end

    it 'accepts the unsubscribe when the streaming push fails during the request, and the deletion job can send the event' do
      world = world_with(1)
      list = Fabricate(:list, account: user.account)
      save_routes(world, home: true, list_ids: [list.id])
      ExternalBridge::StreamControlWorker.clear
      allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      deletion = unsubscribe!(world)

      expect(deletion).to be_queued
      expect(deletion.control_enqueued_at).to be_nil
      expect(deletion.route_targets).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      expect(world[:subscription].reload.state).to eq 'deleting'
      expect(ExternalFeedRoute.where(external_subscription_id: world[:subscription].id)).to be_empty
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1

      allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_call_original
      ExternalBridge::StreamControlWorker.clear
      expect(ExternalBridge::RSS::SubscriptionRemovedNotice.push!(deletion.reload)).to be true

      expect(deletion.reload.control_enqueued_at).to be_present
      payload = ExternalBridge::StreamControlWorker.jobs.last['args'].second
      expect(payload['reason']).to eq 'subscription_removed'
      expect(payload['subscription_id']).to eq world[:subscription].id.to_s
      expect(payload['targets']).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      expect(ExternalBridge::RSS::SubscriptionRemovedNotice.push!(deletion)).to be false
      expect(ExternalBridge::StreamControlWorker.jobs.size).to eq 1
    end

    it 'does not record the streaming event when Sidekiq does not accept the job' do
      world = world_with(1)
      save_routes(world, home: true, list_ids: [])
      allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_return(nil)

      deletion = unsubscribe!(world)

      expect(deletion.control_enqueued_at).to be_nil
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1

      allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_call_original
      ExternalBridge::StreamControlWorker.clear
      expect(ExternalBridge::RSS::SubscriptionRemovedNotice.push!(deletion.reload)).to be true
      expect(deletion.reload.control_enqueued_at).to be_present
      expect(ExternalBridge::StreamControlWorker.jobs.size).to eq 1
    end

    it 'still enqueues the deletion when recording the streaming event raises' do
      world = world_with(1)
      save_routes(world, home: true, list_ids: [])
      secret = 'SECRET_SQL_DETAIL_9f3'
      lines = []
      allow(Rails.logger).to receive(:info) { |line| lines << line.to_s }
      allow_any_instance_of(ExternalSubscriptionDeletion).to receive(:update_columns).and_wrap_original do |method, attrs|
        raise ActiveRecord::StatementInvalid, secret if attrs.key?(:control_enqueued_at)

        method.call(attrs)
      end

      deletion = unsubscribe!(world)

      expect(deletion.reload.control_enqueued_at).to be_nil
      expect(world[:subscription].reload.state).to eq 'deleting'
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
      expect(lines.join("\n")).to include('enqueue_failed')
      expect(lines.join("\n")).not_to include(secret)
    end

    it 'keeps trying a missed streaming event after the deletion has completed, for one day' do
      world = world_with(1)
      save_routes(world, home: true, list_ids: [])
      allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_return(nil)
      deletion = unsubscribe!(world)
      runner.call(deletion.id)
      expect(deletion.reload).to be_completed
      expect(deletion.control_enqueued_at).to be_nil
      allow(ExternalBridge::StreamControlWorker).to receive(:perform_async).and_call_original
      ExternalBridge::StreamControlWorker.clear

      expect(scheduler.perform).to be_a(Integer)

      expect(deletion.reload.control_enqueued_at).to be_present
      expect(ExternalBridge::StreamControlWorker.jobs.size).to eq 1
      payload = ExternalBridge::StreamControlWorker.jobs.last['args'].second
      expect(payload['reason']).to eq 'subscription_removed'

      older = unsubscribe!(world_with(1))
      older.update_columns(state: 'completed', control_enqueued_at: nil, finished_at: Time.current, requested_at: 2.days.ago)
      ExternalBridge::StreamControlWorker.clear
      scheduler.perform
      expect(older.reload.control_enqueued_at).to be_nil
      expect(ExternalBridge::StreamControlWorker.jobs).to be_empty
    end

    it 'keeps the subscription fenced and the record queued when Sidekiq refuses the push' do
      world = world_with(2)
      allow(ExternalBridge::RSS::SubscriptionDeletionWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      deletion = unsubscribe!(world)

      expect(deletion).to be_queued
      expect(world[:subscription].reload.state).to eq 'deleting'
      expect(deletion.next_run_at).to be > Time.current
      expect(deletion.next_run_at).to be <= ExternalBridge::RSS::Unsubscribe::DISPATCH_GRACE.from_now
    end

    it 'does not fence anything when the transaction fails' do
      world = world_with(1)
      allow(ExternalSubscriptionDeletion).to receive(:create!).and_raise(ActiveRecord::StatementInvalid)

      expect { unsubscribe!(world) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(world[:subscription].reload.state).to eq 'active'
      expect(ExternalSubscriptionDeletion.count).to eq 0
    end
  end

  describe 'the fence' do
    it 'does not let a stale model write a projection after the fence' do
      world = world_with(1)
      stale = ExternalSubscription.find(world[:subscription].id)
      resources = world[:source].external_resources.to_a
      fresh = add_resource(world, 'late')
      unsubscribe!(world)
      expect(stale.state).to eq 'active'

      result = ExternalBridge::RSS::Materialize.new.call(subscription: stale, resources: resources + [fresh])

      expect(result.ran).to be false
      expect(ExternalStatusProjection.where(user_id: user.id, external_resource_id: fresh.id)).to be_empty
      expect(ExternalProjectionFailure.where(external_subscription_id: stale.id)).to be_empty
    end

    it 'does not let a stale refresh rewrite an existing projection' do
      world = world_with(1)
      stale = ExternalSubscription.find(world[:subscription].id)
      world[:resource].update!(title: 'Changed', body: 'A new body after the fence', revision: 'rev-2')
      unsubscribe!(world)

      ExternalBridge::RSS::Materialize.new.call(subscription: stale, resources: [world[:resource].reload])

      expect(world[:status].reload.text).to eq 'Secret article body'
      expect(world[:marker].reload.last_seen_revision).to eq 'rev-1'
    end

    it 'does not let a stale outcome write active over deleting' do
      world = world_with(1)
      stale = ExternalSubscription.find(world[:subscription].id)
      unsubscribe!(world)

      ExternalBridge::RSS::SubscriptionOutcome.fetch_failure!(stale, 'http_500')
      ExternalBridge::RSS::SubscriptionOutcome.reconcile!(stale, ExternalBridge::RSS::Materialize::Result.new(ran: true, attempted: 0, succeeded: 0, failed: 0, skipped: 0))
      ExternalBridge::RSS::SubscriptionOutcome.terminal!(stale, 'authenticated_source_rejected')

      expect(world[:subscription].reload.state).to eq 'deleting'
      expect(stale.update_unless_deleting!(state: 'active')).to be false
    end

    it 'refuses pause, resume, restore, destination changes, and a new subscription while deleting' do
      world = world_with(1)
      save_routes(world, home: true)
      source = world[:source]
      source.update!(fetched_at: Time.current)
      unsubscribe!(world)
      subscribe = ExternalBridge::RSS::Subscribe.new

      expect { subscribe.pause!(user: user, subscription_id: world[:subscription].id) }.to error_code('subscription_deleting')
      expect { subscribe.resume!(user: user, subscription_id: world[:subscription].id) }.to error_code('subscription_deleting')
      expect { subscribe.restore!(user: user, subscription_id: world[:subscription].id) }.to error_code('subscription_deleting')
      expect { subscribe.call(user: user, url: source.canonical_key) }.to error_code('subscription_deleting')
      expect do
        ExternalBridge::FeedRoutes::Update.new.call(
          user: user, subscription_id: world[:subscription].id, home: true, list_ids: [],
          expected_revision: world[:subscription].reload.feed_routes_revision
        )
      end.to error_code('subscription_deleting')
      expect(ExternalFeedRoute.where(external_subscription_id: world[:subscription].id)).to be_empty
      expect(ExternalBridge::Error.new(:subscription_deleting).http_status).to eq 409
    end

    it 'does not refresh a deleting subscription and does not pick it for the scheduler' do
      world = world_with(1)
      world[:subscription].update_columns(checked_at: 2.days.ago)
      unsubscribe!(world)
      stub_request(:get, world[:source].canonical_key).to_return(status: 200, body: rss_document(''))

      outcome = ExternalBridge::RSS::RefreshSource.new.call(world[:source].id)

      expect(outcome[:outcome]).to eq 'skipped_no_permitted_subscriptions'
      expect(a_request(:get, world[:source].canonical_key)).not_to have_been_made
      expect(ExternalSubscription.active.due_for_refresh.where(id: world[:subscription].id)).to be_empty
    end

    it 'keeps a deleting subscription out of every home and list read even if a route survives' do
      world = external_project_for(user)
      save_routes(world, home: true)
      query = ExternalBridge::Feeds::Query.new(user: user, destination: 'home')
      expect(query.ids(limit: 10)).to eq [world[:status].id]

      world[:subscription].update_columns(state: 'deleting')

      expect(query.ids(limit: 10)).to eq []
      expect(query.eligible_ids([world[:status].id])).to eq []
    end

    it 'takes no new link share on a projection of a deleting subscription' do
      world = external_project_for(user)
      marker = world[:marker].reload
      expect { ExternalBridge::LinkSharing::Ownership.assert_canonical!(user, marker) }.not_to raise_error

      world[:subscription].update_columns(state: 'deleting')

      expect { ExternalBridge::LinkSharing::Ownership.assert_canonical!(user, marker) }.to error_code('subscription_deleting')
    end

    it 'stops the subscriber hand-offs that the API and the page offer' do
      world = world_with(1)
      unsubscribe!(world)

      rows = ExternalServices::RSS.page_for(user).subscriptions
      expect(rows.map(&:state)).to eq ['deleting']
      expect(rows.first).not_to be_pausable
      expect(rows.first).not_to be_resumable
      expect(ExternalServices::RSS.page_for(user).items).to be_empty
    end

    it 'lets the subscribe after completion create a new subscription' do
      world = world_with(1)
      stub_request(:get, world[:source].canonical_key).to_return(status: 200, body: rss_document(rss_item(guid: 'again')))
      deletion = unsubscribe!(world)
      runner.call(deletion.id)

      fresh = ExternalBridge::RSS::Subscribe.new.call(user: user, url: world[:source].canonical_key)

      expect(fresh.id).not_to eq world[:subscription].id
      expect(fresh.state).to eq 'active'
      expect(ExternalSubscriptionDeletion.find(deletion.id)).to be_completed
    end
  end

  def add_resource(world, name)
    ExternalResource.create!(
      external_source: world[:source],
      protocol: 'rss',
      canonical_key: "feed:#{world[:source].canonical_key}\nitem:#{name}",
      title: name,
      body: name,
      canonical_url: "https://example.com/posts/#{name}",
      revision: 'rev-new',
      published_at: Time.utc(2020, 1, 3)
    )
  end

  describe 'the batched purge' do
    before { stub_const('ExternalBridge::RSS::SubscriptionDeletionRunner::MAX_BATCHES', 2) }

    around do |example|
      previous = ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE']
      ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE'] = '10'
      example.run
    ensure
      ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE'] = previous
    end

    it 'finishes a subscription with no projection at once' do
      world = world_with(1)
      ExternalStatusProjection.where(external_subscription_id: world[:subscription].id).find_each do |marker|
        ExternalBridge::ProjectionPurge.purge_status_ids!([marker.status_id])
      end
      deletion = unsubscribe!(world)

      expect(runner.call(deletion.id)).to eq :completed

      deletion.reload
      expect(deletion).to be_completed
      expect(deletion.total_count).to eq 0
      expect(deletion.percent).to eq 100
      expect(deletion.finished_at).to be_present
      expect(ExternalSubscription.exists?(world[:subscription].id)).to be false
    end

    it 'deletes in small batches, keeps the counters equal to the database, and destroys the row last' do
      world = world_with(25)
      deletion = unsubscribe!(world)
      sizes = []
      allow(ExternalBridge::ProjectionPurge).to receive(:purge_ids_in_transaction!).and_wrap_original do |method, ids, **options|
        sizes << ids.size
        method.call(ids, **options)
      end

      expect(runner.call(deletion.id)).to eq :continue
      deletion.reload
      expect(deletion).to be_running
      expect(deletion.total_count).to eq 25
      expect(deletion.deleted_count).to eq 20
      expect(deletion.remaining).to eq 5
      expect(deletion.percent).to eq 80
      expect(projection_count(world)).to eq 5
      expect(ExternalSubscription.find(world[:subscription].id).state).to eq 'deleting'

      expect(runner.call(deletion.id)).to eq :completed
      deletion.reload
      expect(sizes).to eq [10, 10, 5]
      expect(deletion).to be_completed
      expect(deletion.deleted_count).to eq 25
      expect(deletion.remaining).to eq 0
      expect(projection_count(world)).to eq 0
      expect(ExternalSubscription.exists?(world[:subscription].id)).to be false
      expect(ExternalSource.exists?(world[:source].id)).to be true
      expect(ExternalResource.where(external_source_id: world[:source].id)).to exist
    end

    it 'never loads every status id or opens one long transaction' do
      world = world_with(25)
      deletion = unsubscribe!(world)
      plucks = []
      allow_any_instance_of(ActiveRecord::Relation).to receive(:pluck).and_wrap_original do |method, *args|
        plucks << method.receiver.to_sql if args == [:status_id]
        method.call(*args)
      end

      runner.call(deletion.id)

      expect(plucks.size).to be >= 2
      expect(plucks).to all(match(/ORDER BY .external_status_projections.\..status_id. ASC LIMIT 10\z/))
      expect(plucks).to all(include('external_subscription_id'))
    end

    it 'resumes after a failure without double counting and ends with zero projections' do
      world = world_with(25)
      deletion = unsubscribe!(world)
      calls = 0
      allow(ExternalBridge::ProjectionPurge).to receive(:purge_ids_in_transaction!).and_wrap_original do |method, ids, **options|
        calls += 1
        raise ActiveRecord::StatementInvalid, 'SECRET_SQL_DETAIL' if calls == 2

        method.call(ids, **options)
      end

      expect(runner.call(deletion.id)).to eq :failed
      deletion.reload
      expect(deletion).to be_failed
      expect(deletion.last_error_code).to eq 'database_error'
      expect(deletion.attempt_count).to eq 1
      expect(deletion.deleted_count).to eq 10
      expect(deletion.remaining).to eq 15
      expect(deletion.next_run_at).to be > Time.current
      expect(projection_count(world)).to eq 15
      expect(deletion.attributes.values.join).not_to include('SECRET_SQL_DETAIL')

      expect(runner.call(deletion.id)).to eq :stopped
      deletion.update_columns(next_run_at: 1.minute.ago)
      scheduler.perform
      expect(deletion.reload).to be_queued
      expect(deletion.attempt_count).to eq 1

      expect(runner.call(deletion.id)).to eq :continue
      expect(runner.call(deletion.id)).to eq :completed
      deletion.reload
      expect(deletion).to be_completed
      expect(deletion.deleted_count).to eq 25
      expect(deletion.last_error_code).to be_nil
      expect(projection_count(world)).to eq 0
    end

    it 'rolls the counter back together with the delete when the batch fails midway' do
      world = world_with(12)
      deletion = unsubscribe!(world)
      allow_any_instance_of(ExternalBridge::RSS::SubscriptionDeletionRunner).to receive(:record_progress!).and_raise(ActiveRecord::StatementInvalid)

      expect(runner.call(deletion.id)).to eq :failed

      expect(deletion.reload.deleted_count).to eq 0
      expect(projection_count(world)).to eq 12
      expect(Status.where(id: ExternalStatusProjection.where(external_subscription_id: world[:subscription].id).select(:status_id)).count).to eq 12
    end

    it 'does not run a second time against a completed record' do
      world = world_with(2)
      deletion = unsubscribe!(world)
      runner.call(deletion.id)

      expect(ExternalBridge::ProjectionPurge).not_to receive(:purge_ids_in_transaction!)
      expect(runner.call(deletion.id)).to eq :completed
      expect(runner.call(0)).to eq :gone
      expect(deletion.reload.deleted_count).to eq 2
    end

    it 'does not stop for the feature flags: a started deletion always finishes' do
      world = world_with(3)
      deletion = unsubscribe!(world)
      Setting.external_bridge_rss = false
      Setting.external_bridge_feeds = false

      ExternalBridge::RSS::SubscriptionDeletionWorker.new.perform(deletion.id)

      expect(deletion.reload).to be_completed
      expect(projection_count(world)).to eq 0
    end

    it 'queues the next run itself when the budget is used up' do
      world = world_with(25)
      deletion = unsubscribe!(world)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      ExternalBridge::RSS::SubscriptionDeletionWorker.new.perform(deletion.id)

      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.first['at']).to be_present
      ExternalBridge::RSS::SubscriptionDeletionWorker.drain
      expect(deletion.reload).to be_completed
    end

    it 'derives an estimate only from a speed it has observed' do
      world = world_with(25)
      deletion = unsubscribe!(world)
      expect(deletion.eta_seconds).to be_nil

      runner.call(deletion.id)
      deletion.reload
      expect(deletion.eta_seconds).to be_nil.or be_a(Integer)
      deletion.update_columns(started_at: 20.seconds.ago, last_progress_at: Time.current, deleted_count: 10, total_count: 30)
      expect(deletion.reload.eta_seconds).to be_between(35, 45)
      deletion.update_columns(started_at: 0.5.seconds.ago)
      expect(deletion.reload.eta_seconds).to be_nil
    end
  end

  describe 'what stays' do
    it 'keeps another user, the same account roommate, and ordinary posts' do
      world = world_with(2)
      other = Fabricate(:user)
      roommate = share_account_user(user.account)
      other_subscription = ExternalSubscription.create!(user: other, external_source: world[:source], state: 'active')
      roommate_subscription = ExternalSubscription.create!(user: roommate, external_source: world[:source], state: 'active')
      other_status, = ExternalBridge::ProjectionWriter.new.create!(user: other, subscription: other_subscription, resource: world[:resource], text: 'other')
      roommate_status, = ExternalBridge::ProjectionWriter.new.create!(user: roommate, subscription: roommate_subscription, resource: world[:resource], text: 'roommate')
      ordinary = Fabricate(:status, account: user.account, text: 'plain personal post')
      Favourite.create!(account: other.account, status: other_status)
      Bookmark.create!(account: other.account, status: other_status)
      suppressed = ExternalProjectionSuppression.create!(user: other, external_resource: world[:resource])

      runner.call(unsubscribe!(world).id)

      expect(Status.where(id: [other_status.id, roommate_status.id, ordinary.id]).count).to eq 3
      expect(ExternalStatusProjection.where(user_id: [other.id, roommate.id]).count).to eq 2
      expect(Favourite.where(status_id: other_status.id)).to exist
      expect(Bookmark.where(status_id: other_status.id)).to exist
      expect(ExternalProjectionSuppression.exists?(suppressed.id)).to be true
      expect(ExternalSubscription.where(id: [other_subscription.id, roommate_subscription.id]).count).to eq 2
      expect(ExternalSource.exists?(world[:source].id)).to be true
      expect(ExternalResource.exists?(world[:resource].id)).to be true
    end

    it 'removes this user markers of suppression, failure, and route and the owner progress stays' do
      world = world_with(2)
      save_routes(world, home: true)
      ExternalProjectionSuppression.create!(user: user, external_resource: world[:resource])
      resource = add_resource(world, 'failing')
      ExternalProjectionFailure.create!(user: user, external_subscription: world[:subscription], external_resource: resource, error_code: 'import_failed', attempt_count: 1)
      deletion = unsubscribe!(world)

      runner.call(deletion.id)

      expect(ExternalProjectionSuppression.where(user_id: user.id, external_resource_id: world[:source].external_resources.select(:id))).to be_empty
      expect(ExternalProjectionFailure.where(external_subscription_id: world[:subscription].id)).to be_empty
      expect(ExternalFeedRoute.where(external_subscription_id: world[:subscription].id)).to be_empty
      expect(ExternalSubscriptionDeletion.find(deletion.id)).to be_completed
    end
  end

  describe 'stream and link-sharing contracts' do
    it 'sends delete events to the saved destinations even though the routes were removed at accept time' do
      Setting.external_bridge_external_visibility = true
      world = project_for(user)
      list = Fabricate(:list, account: user.account)
      save_routes(world, home: true, list_ids: [list.id])
      world[:status].reload
      expect(world[:status]).to be_external_visibility
      deletion = unsubscribe!(world)
      ExternalBridge::StreamDeleteWorker.clear

      runner.call(deletion.id)

      jobs = ExternalBridge::StreamDeleteWorker.jobs
      expect(jobs.size).to eq 1
      destinations = jobs.first['args'].first.first['destinations']
      expect(destinations).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      expect(Status.exists?(world[:status].id)).to be false
      expect(effects_for(deletion)).to be_empty
    ensure
      Setting.external_bridge_external_visibility = false
    end

    # Home and list both have the projection. The enqueue runs after the batch
    # transaction, so open_transactions during perform_async matches the depth
    # once the runner has returned (the example's own transaction, not the batch).
    def routed_projection
      Setting.external_bridge_external_visibility = true
      world = project_for(user)
      list = Fabricate(:list, account: user.account)
      save_routes(world, home: true, list_ids: [list.id])
      world[:status].reload
      [world, list]
    end

    def track_search_deletes
      updates = []
      current = Object.new
      current.define_singleton_method(:update) { |*args| updates << args }
      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(Chewy).to receive(:strategy).and_return(double(current: current))
      updates
    end

    def delete_entry(jobs)
      jobs.last['args'].first.first
    end

    def effects_for(deletion)
      ExternalSubscriptionDeletionEffect.where(external_subscription_deletion_id: deletion.id).order(:id).to_a
    end

    it 'keeps the delete event, the cache, and the search delete when the enqueue raises after the commit' do
      world, list = routed_projection
      expect(world[:status]).to be_external_visibility
      deletion = unsubscribe!(world)
      cache_key = "statuses/#{world[:status].id}"
      Rails.cache.write(cache_key, 'rendered projection')
      updates = track_search_deletes
      depths = []
      failing = true
      allow(ExternalBridge::StreamDeleteWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        depths << ApplicationRecord.connection.open_transactions
        raise Redis::CannotConnectError, 'down' if failing

        method.call(*args)
      end

      expect(runner.call(deletion.id)).to eq :effects_pending

      deletion.reload
      expect(deletion).to be_running
      expect(deletion.attempt_count).to eq 0
      expect(deletion.last_error_code).to be_nil
      expect(deletion.deleted_count).to eq 1
      expect(Status.exists?(world[:status].id)).to be false
      expect(ExternalStatusProjection.exists?(status_id: world[:status].id)).to be false
      expect(ExternalSubscription.find(world[:subscription].id).state).to eq 'deleting'
      expect(Rails.cache.read(cache_key)).to be_nil
      expect(updates).to include([StatusesIndex, [world[:status].id]])
      expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
      capture = effects_for(deletion).first
      expect(capture.status_id).to eq world[:status].id
      expect(capture.stream_enqueued_at).to be_nil
      expect(capture.cache_cleared_at).to be_present
      expect(capture.search_cleared_at).to be_present
      expect(capture.destinations).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })

      failing = false
      expect(runner.call(deletion.id)).to eq :completed
      expect(ApplicationRecord.connection.open_transactions).to eq depths.first
      expect(depths.uniq).to eq [depths.first]
      entry = delete_entry(ExternalBridge::StreamDeleteWorker.jobs)
      expect(entry['status_id']).to eq world[:status].id.to_s
      expect(entry['destinations']).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      expect(deletion.reload).to be_completed
      expect(effects_for(deletion)).to be_empty
      expect(ExternalSubscription.exists?(world[:subscription].id)).to be false
    ensure
      Setting.external_bridge_external_visibility = false
    end

    it 'keeps the capture when Sidekiq accepts nothing, and the worker tries again without a failure' do
      world, list = routed_projection
      deletion = unsubscribe!(world)
      cache_key = "statuses/#{world[:status].id}"
      Rails.cache.write(cache_key, 'rendered projection')
      updates = track_search_deletes
      allow(ExternalBridge::StreamDeleteWorker).to receive(:perform_async).and_return(nil)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      ExternalBridge::RSS::SubscriptionDeletionWorker.new.perform(deletion.id)

      deletion.reload
      expect(deletion).to be_running
      expect(deletion.attempt_count).to eq 0
      expect(deletion.deleted_count).to eq 1
      expect(effects_for(deletion).first.status_id).to eq world[:status].id
      expect(effects_for(deletion).first.destinations).to contain_exactly(
        { 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s }
      )
      expect(Rails.cache.read(cache_key)).to be_nil
      expect(updates).to include([StatusesIndex, [world[:status].id]])
      expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
      retried = ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.find { |job| job['at'].present? }
      expect(retried['args']).to eq [deletion.id]

      allow(ExternalBridge::StreamDeleteWorker).to receive(:perform_async).and_call_original
      expect(runner.call(deletion.id)).to eq :completed
      entry = delete_entry(ExternalBridge::StreamDeleteWorker.jobs)
      expect(entry['destinations']).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      expect(effects_for(deletion)).to be_empty
    ensure
      Setting.external_bridge_external_visibility = false
    end

    it 'finishes the side effects on the next run when the worker dies after the batch commits' do
      world, list = routed_projection
      deletion = unsubscribe!(world)
      cache_key = "statuses/#{world[:status].id}"
      Rails.cache.write(cache_key, 'rendered projection')
      updates = track_search_deletes
      skip_flush = true
      allow_any_instance_of(ExternalBridge::RSS::SubscriptionDeletionRunner).to receive(:flush_pending_effects!).and_wrap_original do |method, *args|
        method.call(*args) unless skip_flush
      end

      expect(runner.call(deletion.id)).to eq :effects_pending

      deletion.reload
      expect(deletion).to be_running
      expect(deletion.deleted_count).to eq 1
      expect(Status.exists?(world[:status].id)).to be false
      expect(ExternalStatusProjection.exists?(status_id: world[:status].id)).to be false
      expect(Rails.cache.read(cache_key)).to eq 'rendered projection'
      expect(updates).to be_empty
      expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
      expect(effects_for(deletion).first.destinations).to contain_exactly(
        { 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s }
      )
      expect(effects_for(deletion).first.cache_cleared_at).to be_nil
      expect(effects_for(deletion).first.search_cleared_at).to be_nil

      skip_flush = false
      expect(runner.call(deletion.id)).to eq :completed
      expect(Rails.cache.read(cache_key)).to be_nil
      expect(updates).to include([StatusesIndex, [world[:status].id]])
      entry = delete_entry(ExternalBridge::StreamDeleteWorker.jobs)
      expect(entry['status_id']).to eq world[:status].id.to_s
      expect(entry['destinations']).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      expect(effects_for(deletion)).to be_empty
    ensure
      Setting.external_bridge_external_visibility = false
    end

    it 'pushes the same delete again when the worker dies after Sidekiq has accepted it' do
      world, list = routed_projection
      deletion = unsubscribe!(world)
      killed = Class.new(Exception) # rubocop:disable Lint/InheritException -- must escape the runner's StandardError rescue
      first = true
      allow_any_instance_of(ExternalBridge::RSS::SubscriptionDeletionRunner).to receive(:mark_stream!).and_wrap_original do |method, *args|
        raise killed if first

        method.call(*args)
      end

      expect { runner.call(deletion.id) }.to raise_error(killed)

      deletion.reload
      expect(deletion).to be_running
      expect(deletion.attempt_count).to eq 0
      expect(deletion.deleted_count).to eq 1
      expect(Status.exists?(world[:status].id)).to be false
      expect(ExternalBridge::StreamDeleteWorker.jobs.size).to eq 1
      expect(effects_for(deletion).first.status_id).to eq world[:status].id
      expect(effects_for(deletion).first.stream_enqueued_at).to be_nil

      first = false
      expect(runner.call(deletion.id)).to eq :completed
      expect(ExternalBridge::StreamDeleteWorker.jobs.size).to eq 2
      ExternalBridge::StreamDeleteWorker.jobs.each do |job|
        entry = job['args'].first.first
        expect(entry['status_id']).to eq world[:status].id.to_s
        expect(entry['destinations']).to contain_exactly({ 'type' => 'home' }, { 'type' => 'list', 'id' => list.id.to_s })
      end
      expect(effects_for(deletion)).to be_empty
    ensure
      Setting.external_bridge_external_visibility = false
    end

    it 'keeps the status retryable when cache fails and the stream enqueue succeeds' do
      world, = routed_projection
      deletion = unsubscribe!(world)
      cache_key = "statuses/#{world[:status].id}"
      Rails.cache.write(cache_key, 'rendered projection')
      updates = track_search_deletes
      allow(Rails.cache).to receive(:delete).and_raise(RuntimeError, 'cache down')

      expect(runner.call(deletion.id)).to eq :effects_pending

      row = effects_for(deletion).first
      expect(row.cache_cleared_at).to be_nil
      expect(row.search_cleared_at).to be_present
      expect(row.stream_enqueued_at).to be_present
      expect(updates).to include([StatusesIndex, [world[:status].id]])
      expect(Rails.cache.read(cache_key)).to eq 'rendered projection'
      expect(deletion.reload).to be_running
      expect(ExternalBridge::StreamDeleteWorker.jobs.size).to eq 1

      allow(Rails.cache).to receive(:delete).and_call_original
      expect(runner.call(deletion.id)).to eq :completed
      expect(Rails.cache.read(cache_key)).to be_nil
      expect(effects_for(deletion)).to be_empty
      expect(updates.size).to eq 1
    ensure
      Setting.external_bridge_external_visibility = false
    end

    it 'keeps the status retryable when search fails and the stream enqueue succeeds' do
      world, = routed_projection
      deletion = unsubscribe!(world)
      cache_key = "statuses/#{world[:status].id}"
      Rails.cache.write(cache_key, 'rendered projection')
      attempts = 0
      failing = true
      current = Object.new
      current.define_singleton_method(:update) do |*|
        attempts += 1
        raise 'search down' if failing
      end
      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(Chewy).to receive(:strategy).and_return(double(current: current))

      expect(runner.call(deletion.id)).to eq :effects_pending

      row = effects_for(deletion).first
      expect(row.cache_cleared_at).to be_present
      expect(row.search_cleared_at).to be_nil
      expect(row.stream_enqueued_at).to be_present
      expect(Rails.cache.read(cache_key)).to be_nil
      expect(deletion.reload).to be_running
      expect(attempts).to be >= 1

      failing = false
      expect(runner.call(deletion.id)).to eq :completed
      expect(attempts).to be > 1
      expect(effects_for(deletion)).to be_empty
    ensure
      Setting.external_bridge_external_visibility = false
    end

    it 'recovers cache and search for a personal projection when the worker dies after the commit' do
      Setting.external_bridge_external_visibility = false
      world = project_for(user)
      expect(world[:status]).to be_personal_visibility
      deletion = unsubscribe!(world)
      cache_key = "statuses/#{world[:status].id}"
      Rails.cache.write(cache_key, 'rendered projection')
      updates = track_search_deletes
      skip_flush = true
      allow_any_instance_of(ExternalBridge::RSS::SubscriptionDeletionRunner).to receive(:flush_pending_effects!).and_wrap_original do |method, *args|
        method.call(*args) unless skip_flush
      end

      expect(runner.call(deletion.id)).to eq :effects_pending

      expect(deletion.reload).to be_running
      expect(deletion.deleted_count).to eq 1
      expect(Status.exists?(world[:status].id)).to be false
      expect(Rails.cache.read(cache_key)).to eq 'rendered projection'
      expect(updates).to be_empty
      expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
      expect(effects_for(deletion).first.destinations).to be_nil
      expect(effects_for(deletion).first.cache_cleared_at).to be_nil
      expect(effects_for(deletion).first.search_cleared_at).to be_nil

      skip_flush = false
      expect(runner.call(deletion.id)).to eq :completed
      expect(Rails.cache.read(cache_key)).to be_nil
      expect(updates).to include([StatusesIndex, [world[:status].id]])
      expect(ExternalBridge::StreamDeleteWorker.jobs).to be_empty
      expect(effects_for(deletion)).to be_empty
    end

    it 'stops further deletes while open effect rows are at the cap and a stream enqueue is refused' do
      previous = ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE']
      ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE'] = '10'
      stub_const('ExternalBridge::RSS::SubscriptionDeletionRunner::EFFECTS_CAP', 10)
      Setting.external_bridge_external_visibility = true
      world = world_with(25)
      save_routes(world, home: true)
      deletion = unsubscribe!(world)
      allow(ExternalBridge::StreamDeleteWorker).to receive(:perform_async).and_return(nil)

      expect(runner.call(deletion.id)).to eq :effects_pending

      expect(deletion.reload.deleted_count).to eq 10
      expect(projection_count(world)).to eq 15
      expect(effects_for(deletion).size).to eq 10
      expect(deletion).to be_running
      expect(deletion.attempt_count).to eq 0

      allow(ExternalBridge::StreamDeleteWorker).to receive(:perform_async).and_call_original
      expect(runner.call(deletion.id)).to eq :completed
      expect(projection_count(world)).to eq 0
      expect(effects_for(deletion)).to be_empty
    ensure
      ENV['EXTERNAL_RSS_DELETION_BATCH_SIZE'] = previous
      Setting.external_bridge_external_visibility = false
    end

    it 'purges with a physical DELETE: no discard, no RemoveStatusService, no ActivityPub Delete' do
      world = world_with(3)
      expect(RemoveStatusService).not_to receive(:new)
      expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)
      expect_any_instance_of(Status).not_to receive(:discard)

      runner.call(unsubscribe!(world).id)

      expect(Status.unscoped.where(id: ExternalStatusProjection.where(external_subscription_id: world[:subscription].id).select(:status_id))).to be_empty
      expect(projection_count(world)).to eq 0
    end

    it 'ends the link share, hands the wrapper to ExternalBridge::LinkWrapperRemovalWorker, and leaves the reference note alone' do
      stub_request(:any, %r{\Ahttps://example\.com/}).to_return(status: 200, body: '<html><head><title>x</title></head></html>', headers: { 'Content-Type' => 'text/html' })
      world = external_project_for(user)
      world[:source].update!(title: 'Safe Feed Title')
      world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(5)}")
      enable_external_bridge_link_sharing!(user)
      ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: 'public')
      result = ExternalBridge::LinkSharing::Boost.call(user: user, status: world[:status])
      result.boost.update_columns(announced_at: Time.current)
      removals = []
      allow(ExternalBridge::LinkWrapperRemovalWorker).to receive(:perform_async) { |id| removals << id }

      runner.call(unsubscribe!(world).id)

      row = ExternalProjectionLinkBoost.find(result.boost.id)
      expect(row.state).to eq 'undone'
      expect(row.ended_reason).to eq 'projection_purged'
      expect(removals).to eq [result.wrapper.id]
      expect(Status.find(result.reference.id).deleted_at).to be_nil
      expect(ExternalProjectionLinkBoostState.where(projection_status_id: world[:status].id)).to be_empty
    end
  end

  describe 'recovery' do
    it 'pushes a record whose first push was lost, once, and holds it afterwards' do
      world = world_with(2)
      deletion = unsubscribe!(world)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear
      expect(scheduler.perform).to eq 0

      deletion.update_columns(next_run_at: 1.minute.ago)
      expect(scheduler.perform).to eq 1
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
      expect(scheduler.perform).to eq 0
      expect(deletion.reload.next_run_at).to be > Time.current

      ExternalBridge::RSS::SubscriptionDeletionWorker.drain
      expect(deletion.reload).to be_completed
    end

    it 'takes over a running record whose worker died after its lease' do
      world = world_with(2)
      deletion = unsubscribe!(world)
      deletion.update_columns(state: 'running', started_at: 10.minutes.ago, last_progress_at: 9.minutes.ago, next_run_at: 1.minute.ago)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      expect(scheduler.perform).to eq 1
      ExternalBridge::RSS::SubscriptionDeletionWorker.drain

      expect(deletion.reload).to be_completed
      expect(projection_count(world)).to eq 0
    end

    it 'retries a failed record with attempts left and leaves an exhausted one for the owner' do
      world = world_with(1)
      other_world = project_for(user)
      retrying = unsubscribe!(world)
      exhausted = unsubscribe!(other_world)
      retrying.update_columns(state: 'failed', attempt_count: 1, next_run_at: 1.minute.ago)
      exhausted.update_columns(state: 'failed', attempt_count: 5, next_run_at: nil)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      expect(scheduler.perform).to eq 1

      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.map { |job| job['args'].first }).to eq [retrying.id]
    end

    it 'does not let a late or duplicate job run a failed record, whether it waits for the scheduler or for the owner' do
      world = world_with(3)
      deletion = unsubscribe!(world)
      deletion.update_columns(state: 'failed', attempt_count: 5, next_run_at: nil, last_error_code: 'database_error', total_count: 3, deleted_count: 0)
      expect(ExternalBridge::ProjectionPurge).not_to receive(:purge_ids_in_transaction!)

      expect(runner.call(deletion.id)).to eq :stopped
      ExternalBridge::RSS::SubscriptionDeletionWorker.new.perform(deletion.id)

      expect(deletion.reload).to be_failed
      expect(deletion.attempt_count).to eq 5
      expect(projection_count(world)).to eq 3

      deletion.update_columns(attempt_count: 2, next_run_at: 5.minutes.from_now)
      expect(runner.call(deletion.id)).to eq :stopped
      expect(deletion.reload).to be_failed
      expect(deletion.next_run_at).to be > 4.minutes.from_now
    end

    it 'turns a due failed record into queued before pushing it, and holds a due queued one' do
      world = world_with(2)
      other = project_for(user)
      failed = unsubscribe!(world)
      stuck = unsubscribe!(other)
      failed.update_columns(state: 'failed', attempt_count: 1, next_run_at: 1.minute.ago)
      stuck.update_columns(state: 'queued', next_run_at: 1.minute.ago)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      expect(scheduler.perform).to eq 2

      expect(failed.reload).to be_queued
      expect(failed.attempt_count).to eq 1
      expect(stuck.reload).to be_queued
      expect([failed, stuck].map(&:next_run_at)).to all(be > Time.current)
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 2
      expect(scheduler.perform).to eq 0
    end

    it 'goes from a failure to completion by itself through the scheduler, with the card still polling' do
      world = world_with(3)
      deletion = unsubscribe!(world)
      allow(ExternalBridge::ProjectionPurge).to receive(:purge_ids_in_transaction!).and_raise(ActiveRecord::StatementInvalid)
      runner.call(deletion.id)
      row = ExternalServices::RSS.deletion_row_for(user, deletion.id)
      expect(row).to be_polling
      expect(row).to be_retrying
      expect(row.retryable?).to be false
      allow(ExternalBridge::ProjectionPurge).to receive(:purge_ids_in_transaction!).and_call_original
      deletion.update_columns(next_run_at: 1.minute.ago)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear

      expect(scheduler.perform).to eq 1
      ExternalBridge::RSS::SubscriptionDeletionWorker.drain

      row = ExternalServices::RSS.deletion_row_for(user, deletion.id)
      expect(row).to be_finished
      expect(row).not_to be_polling
      expect(row.as_json).to include(state: 'completed', retrying: false, percent: 100)
    end

    it 'lets the owner retry only a failed record' do
      world = world_with(2)
      deletion = unsubscribe!(world)
      ExternalBridge::RSS::SubscriptionDeletionWorker.clear
      retry_job = ExternalBridge::RSS::SubscriptionDeletionRetry.new

      expect(retry_job.call(user: user, deletion_id: deletion.id)).to be_queued
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 0

      deletion.update_columns(state: 'failed', attempt_count: 2, next_run_at: 5.minutes.from_now)
      expect(retry_job.call(user: user, deletion_id: deletion.id)).to be_failed
      expect(deletion.reload.attempt_count).to eq 2
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 0

      deletion.update_columns(state: 'failed', attempt_count: 5, next_run_at: nil, last_error_code: 'database_error')
      result = retry_job.call(user: user, deletion_id: deletion.id)
      expect(result).to be_queued
      expect(result.attempt_count).to eq 0
      expect(ExternalBridge::RSS::SubscriptionDeletionWorker.jobs.size).to eq 1
      expect { retry_job.call(user: Fabricate(:user), deletion_id: deletion.id) }.to error_code('not_found')
    end

    it 'drops completed records after the retention window only' do
      world = world_with(1)
      old = unsubscribe!(world)
      runner.call(old.id)
      fresh_world = world_with(1)
      fresh = unsubscribe!(fresh_world)
      runner.call(fresh.id)
      old.update_columns(finished_at: (ExternalSubscriptionDeletion::RETENTION + 1.day).ago)

      scheduler.perform

      expect(ExternalSubscriptionDeletion.exists?(old.id)).to be false
      expect(ExternalSubscriptionDeletion.exists?(fresh.id)).to be true
    end
  end

  describe 'user deletion' do
    it 'removes the progress records with the user and lets a late job exit quietly' do
      world = world_with(2)
      deletion = unsubscribe!(world)

      ExternalBridge::DeleteUser.call(user)

      expect(ExternalSubscriptionDeletion.exists?(deletion.id)).to be false
      expect(runner.call(deletion.id)).to eq :gone
    end
  end

  describe 'the log' do
    it 'writes counters and ids only' do
      world = world_with(2)
      deletion = unsubscribe!(world)
      lines = []
      allow(Rails.logger).to receive(:info) { |line| lines << line.to_s }

      runner.call(deletion.id)

      joined = lines.join("\n")
      expect(joined).to include('[ExternalBridge::RSS::Deletion] event=started')
      expect(joined).to match(/event=batch .*job_id=#{deletion.id} subscription_id=#{world[:subscription].id}.* batch=2 deleted=2 remaining=0/)
      expect(joined).to match(/event=completed .*elapsed_ms=\d+/)
      expect(joined).not_to include(world[:source].canonical_key)
      expect(joined).not_to include('Secret article body')
    end
  end
end

# rubocop:enable Metrics/BlockLength
