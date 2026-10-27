# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe 'RSS presentation reconcile' do
  let(:owner) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:world) { project_for(owner, body: 'Secret article body') }

  before do
    enable_external_bridge_rss!(owner, other)
    world
  end

  def run_worker(subscription, revision = nil)
    ActiveRecord::Base.connection.clear_query_cache
    subscription.reload
    ExternalBridge::RSS::PresentationReconcileWorker.new.perform(
      subscription.id,
      revision || subscription.presentation_revision,
      0,
      subscription.presentation_lease_token
    )
  end

  def save!(subscription, media_sensitive:, cw_enabled:)
    ExternalBridge::RSS::PresentationUpdate.new.call(
      user: subscription.user,
      subscription_id: subscription.id,
      media_sensitive: media_sensitive,
      cw_enabled: cw_enabled
    )
  end

  it 'rewrites only this subscription and keeps the status, favourite, and shared cache' do
    favourite = Fabricate(:favourite, account: owner.account, status: world[:status])
    bookmark = Fabricate(:bookmark, account: owner.account, status: world[:status])
    note = Fabricate(:status, account: owner.account, text: 'ordinary public text', visibility: :public, sensitive: false, spoiler_text: '')
    other_status, = ExternalBridge::ProjectionWriter.new.create!(
      user: other,
      subscription: ExternalSubscription.create!(user: other, external_source: world[:source], state: 'active'),
      resource: world[:resource],
      text: 'other body'
    )
    resource_title = world[:resource].title
    source_title = world[:source].title
    distributed = []
    allow(DistributionWorker).to receive(:perform_async) { |*args| distributed << args }
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |*args| distributed << args }
    Rails.cache.write("statuses/#{world[:status].id}", 'stale')

    save!(world[:subscription], media_sensitive: true, cw_enabled: true)

    status = world[:status].reload
    expect(status.id).to eq(world[:status].id)
    expect(status.sensitive).to eq(true)
    expect(status.spoiler_text).to eq('Imported title')
    expect(status.text).to include('Secret article body')
    expect(status.text).not_to include('Imported title')
    expect(status.visibility).to eq(world[:status].visibility)
    expect(status.uri).to be_nil
    expect(status.external_projection).to eq(true)
    expect(favourite.reload.status_id).to eq(status.id)
    expect(bookmark.reload.status_id).to eq(status.id)
    expect(note.reload.attributes.slice('text', 'spoiler_text', 'sensitive')).to eq(
      'text' => 'ordinary public text',
      'spoiler_text' => '',
      'sensitive' => false
    )
    expect(other_status.reload.text).to eq('other body')
    expect(other_status.spoiler_text).to eq('')
    expect(other_status.sensitive).to eq(false)
    expect(world[:resource].reload.title).to eq(resource_title)
    expect(world[:source].reload.title).to eq(source_title)
    expect(Rails.cache.read("statuses/#{status.id}")).to be_nil
    expect(distributed).to eq([])
    subscription = world[:subscription].reload
    expect(subscription.presentation_state).to eq('settled')
    expect(subscription.presentation_revision).to eq(subscription.presentation_applied_revision)
  end

  it 'lets the latest save win across on, off, and on, and ignores a stale generation' do
    save!(world[:subscription], media_sensitive: false, cw_enabled: true)
    expect(world[:status].reload.spoiler_text).to eq('Imported title')

    Sidekiq::Testing.fake! do
      save!(world[:subscription].reload, media_sensitive: true, cw_enabled: false)
    end
    expect(world[:subscription].reload.presentation_revision).to eq(2)
    expect(world[:status].reload.spoiler_text).to eq('Imported title')

    run_worker(world[:subscription], 1)
    expect(world[:status].reload.spoiler_text).to eq('Imported title')
    expect(world[:status].sensitive).to eq(false)

    run_worker(world[:subscription], 2)
    expect(world[:status].reload.spoiler_text).to eq('')
    expect(world[:status].text).to include('Imported title')
    expect(world[:status].sensitive).to eq(true)
    expect(world[:subscription].reload.presentation_applied_revision).to eq(2)

    save!(world[:subscription], media_sensitive: true, cw_enabled: true)
    expect(world[:status].reload.spoiler_text).to eq('Imported title')
    expect(world[:status].sensitive).to eq(true)
    expect(world[:subscription].reload.presentation_state).to eq('settled')
  end

  it 'updates a paused or errored subscription while import is off, and skips deletion' do
    Setting.external_bridge_rss = false
    world[:subscription].update!(state: 'paused')
    save!(world[:subscription], media_sensitive: true, cw_enabled: true)
    expect(world[:status].reload.sensitive).to eq(true)
    expect(world[:status].spoiler_text).to eq('Imported title')

    world[:status].update_columns(sensitive: false, spoiler_text: '')
    world[:subscription].reload.update_columns(
      state: 'error',
      presentation_applied_revision: 0,
      presentation_lease_until: nil,
      presentation_lease_token: 'retry-token'
    )
    run_worker(world[:subscription])
    expect(world[:status].reload.sensitive).to eq(true)
    expect(world[:status].spoiler_text).to eq('Imported title')

    text = world[:status].text
    world[:subscription].update_columns(
      state: 'deleting',
      presentation_applied_revision: 0,
      presentation_lease_until: nil,
      presentation_lease_token: 'doomed-token',
      cw_enabled: false
    )
    run_worker(world[:subscription])
    expect(world[:status].reload.text).to eq(text)
    expect(world[:status].spoiler_text).to eq('Imported title')
  end

  it 'walks a large set in pages and does not stream when the status already matches' do
    stub_const('ExternalBridge::RSS::PresentationReconcileWorker::BATCH', 2)
    extra = Array.new(3) do |index|
      resource = ExternalResource.create!(
        external_source: world[:source],
        protocol: 'rss',
        canonical_key: "#{world[:source].canonical_key}\nitem:extra-#{index}",
        title: "Extra #{index}",
        body: "Body #{index}",
        canonical_url: "https://example.com/extra/#{index}",
        byline: 'Ada',
        revision: "rev-extra-#{index}",
        published_at: Time.utc(2020, 1, 3)
      )
      status, = ExternalBridge::ProjectionWriter.new.create!(
        user: owner,
        subscription: world[:subscription],
        resource: resource,
        text: "Body #{index}"
      )
      status
    end

    save!(world[:subscription], media_sensitive: false, cw_enabled: true)
    extra.each(&:reload)
    expect(extra.map(&:spoiler_text)).to eq(['Extra 0', 'Extra 1', 'Extra 2'])
    expect(world[:subscription].reload.presentation_state).to eq('settled')

    allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!)
    world[:subscription].update_columns(presentation_applied_revision: 0, presentation_lease_until: nil)
    run_worker(world[:subscription])
    expect(ExternalBridge::Streaming::Scheduler).not_to have_received(:bump_and_schedule_content!)
  end

  it 'reads the saved choices during import instead of a stale subscription object' do
    stale = ExternalSubscription.find(world[:subscription].id)
    world[:subscription].update_columns(cw_enabled: true, media_sensitive: true, presentation_revision: 4, presentation_applied_revision: 4)

    ExternalBridge::RSS::Materialize.new.call(subscription: stale, resources: [world[:resource]])

    status = world[:status].reload
    expect(status.spoiler_text).to eq('Imported title')
    expect(status.sensitive).to eq(true)
    expect(status.text).not_to include('Imported title')
    expect(stale.cw_enabled).to eq(false)
  end

  it 'follows a title change into the warning and leaves the warning when it is off' do
    save!(world[:subscription], media_sensitive: false, cw_enabled: true)
    world[:resource].update!(title: '改題', revision: 'rev-2')

    ExternalBridge::RSS::Materialize.new.call(subscription: world[:subscription].reload, resources: [world[:resource].reload])

    expect(world[:status].reload.spoiler_text).to eq('改題')
    expect(world[:resource].reload.title).to eq('改題')

    save!(world[:subscription].reload, media_sensitive: false, cw_enabled: false)
    expect(world[:status].reload.spoiler_text).to eq('')
    expect(world[:status].text).to include('改題')
  end

  it 'recovers a generation whose worker never ran' do
    world[:subscription].update_columns(
      cw_enabled: true,
      media_sensitive: true,
      presentation_revision: 7,
      presentation_applied_revision: 0,
      presentation_lease_until: 1.hour.ago,
      presentation_error: 'reconcile_failed',
      updated_at: 10.minutes.ago
    )

    expect(Scheduler::ExternalBridgeRSSPresentationScheduler.new.perform).to eq(1)
    expect(world[:status].reload.sensitive).to eq(true)
    expect(world[:status].spoiler_text).to eq('Imported title')
    expect(world[:subscription].reload.presentation_applied_revision).to eq(7)
    expect(world[:subscription].presentation_error).to be_nil
  end

  it 'does not queue a second pass while a lease is held or the subscription is being removed' do
    world[:subscription].update_columns(
      cw_enabled: true,
      presentation_revision: 3,
      presentation_applied_revision: 0,
      presentation_lease_until: 10.minutes.from_now
    )
    expect(ExternalBridge::RSS::PresentationReconcileWorker).not_to receive(:perform_async)
    expect(Scheduler::ExternalBridgeRSSPresentationScheduler.new.perform).to eq(0)

    world[:subscription].update_columns(state: 'deleting', presentation_lease_until: 1.hour.ago)
    expect(Scheduler::ExternalBridgeRSSPresentationScheduler.new.perform).to eq(0)
    expect(world[:status].reload.spoiler_text).to eq('')
  end

  it 'refuses a delayed worker after the scheduler has claimed the expired lease' do
    world[:subscription].update_columns(
      cw_enabled: true,
      presentation_revision: 6,
      presentation_applied_revision: 0,
      presentation_lease_token: 'delayed-worker',
      presentation_lease_until: 1.hour.ago,
      presentation_error: nil
    )
    ExternalBridge::RSS::PresentationReconcileWorker.clear

    Sidekiq::Testing.fake! do
      expect(Scheduler::ExternalBridgeRSSPresentationScheduler.new.perform).to eq(1)
    end

    job = ExternalBridge::RSS::PresentationReconcileWorker.jobs.last
    expect(job['args'][3]).not_to eq('delayed-worker')
    ExternalBridge::RSS::PresentationReconcileWorker.new.perform(world[:subscription].id, 6, 0, 'delayed-worker')
    expect(world[:status].reload.spoiler_text).to eq('')

    ExternalBridge::RSS::PresentationReconcileWorker.new.perform(*job['args'])
    expect(world[:status].reload.spoiler_text).to eq('Imported title')
    expect(world[:subscription].reload.presentation_applied_revision).to eq(6)
  end

  it 'does not clear a newer lease when an older job exhausts its retries' do
    world[:subscription].update_columns(
      cw_enabled: true,
      presentation_revision: 9,
      presentation_applied_revision: 0,
      presentation_lease_token: 'live-owner',
      presentation_lease_until: 10.minutes.from_now
    )

    ExternalBridge::RSS::PresentationReconcileWorker.sidekiq_retries_exhausted_block.call(
      'args' => [world[:subscription].id, 9, 0, nil]
    )
    ExternalBridge::RSS::PresentationReconcileWorker.sidekiq_retries_exhausted_block.call(
      'args' => [world[:subscription].id, 9, 40, 'stale-owner']
    )

    subscription = world[:subscription].reload
    expect(subscription.presentation_lease_token).to eq('live-owner')
    expect(subscription.presentation_error).to be_nil
    expect(subscription.presentation_lease_until).to be_present

    ExternalBridge::RSS::PresentationReconcileWorker.sidekiq_retries_exhausted_block.call(
      'args' => [world[:subscription].id, 9, 40, 'live-owner']
    )

    subscription.reload
    expect(subscription.presentation_error).to eq('reconcile_failed')
    expect(subscription.presentation_lease_token).to be_nil
    expect(subscription.presentation_lease_until).to be_nil
  end

  it 'locks the subscription row before comparing the saved choices' do
    sqls = []
    callback = lambda do |*, payload|
      sqls << payload[:sql].to_s
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      save!(world[:subscription], media_sensitive: true, cw_enabled: false)
    end

    lock_at = sqls.index { |sql| sql.include?('FOR UPDATE') }
    write_at = sqls.index { |sql| sql.include?('presentation_revision') && sql.match?(/update/i) }
    expect(lock_at).not_to be_nil
    expect(write_at).to be > lock_at
  end

  it 'does not bump the generation when the choices are unchanged' do
    expect(ExternalBridge::RSS::PresentationReconcileWorker).not_to receive(:perform_async)

    saved = save!(world[:subscription], media_sensitive: false, cw_enabled: false)

    expect(saved.presentation_revision).to eq(0)
    expect(world[:status].reload.text).to eq('Secret article body')
  end
end

# rubocop:enable Metrics/BlockLength
