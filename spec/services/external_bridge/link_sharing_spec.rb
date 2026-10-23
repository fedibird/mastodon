# frozen_string_literal: true

# The safety matrix is one contract. Splitting it would hide the combinations.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'
require Rails.root.join('db/migrate/20261026120000_create_external_link_sharing.rb')
require Rails.root.join('db/migrate/20261027120000_add_external_link_reference_published_at.rb')
require Rails.root.join('db/migrate/20261028120000_add_external_link_reference_next_recovery_at.rb')

describe 'ExternalBridge link sharing', type: :model do
  def error_code(code)
    raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq(code) }
  end

  def grant!(user, visibility = 'public')
    ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: visibility)
  end

  def share!(user, projection, scope = 'public')
    ExternalBridge::LinkSharing::EnsureReference.call(user: user, projection: projection, scope: scope)
  end

  def plant_secrets!(world, url)
    world[:source].update!(title: 'Safe Feed Title')
    world[:resource].update!(
      title: 'SECRET_ARTICLE_TITLE_9f3aa1',
      body: 'SECRET_BODY_9f3aa1',
      byline: 'SECRET_BYLINE_9f3aa1',
      canonical_url: url
    )
    world[:status].update_columns(text: 'SECRET_PROJECTION_TEXT_9f3aa1', spoiler_text: 'SECRET_CW_9f3aa1')
    attachment = {
      account_id: world[:status].account_id,
      status_id: world[:status].id,
      remote_url: '',
      type: 0,
      description: 'SECRET_MEDIA_9f3aa1',
      created_at: Time.current,
      updated_at: Time.current,
    }
    MediaAttachment.insert!(attachment)
    poll = Poll.create!(
      account: world[:status].account,
      status: world[:status],
      options: %w(SECRET_POLL_9f3aa1 SECRET_POLL_ALT_9f3aa1),
      expires_at: 1.day.from_now
    )
    world[:status].update_columns(poll_id: poll.id)
    world
  end

  def secret_tokens
    %w(
      SECRET_ARTICLE_TITLE_9f3aa1
      SECRET_BODY_9f3aa1
      SECRET_BYLINE_9f3aa1
      SECRET_PROJECTION_TEXT_9f3aa1
      SECRET_CW_9f3aa1
      SECRET_MEDIA_9f3aa1
      SECRET_POLL_9f3aa1
      SECRET_POLL_ALT_9f3aa1
    )
  end

  def plant_unpublished_reference!(user, world, url)
    note = Status.create!(
      account: user.account,
      text: "Safe Feed Title\nRSS\n#{url}",
      visibility: :public,
      searchability: :public,
      local: true,
      external_projection: false
    )
    ExternalProjectionLinkReference.create!(
      user_id: user.id,
      account_id: user.account_id,
      external_status_projection_id: nil,
      projection_status_id: world[:status].id,
      reference_status_id: note.id,
      visibility: 'public',
      canonical_url: url,
      policy_revision: 1,
      state: 'active'
    )
  end

  def reference_blob(status, viewer)
    status.reload
    card_bits = status.preview_cards.flat_map { |card| [card.title, card.description, card.url] }
    rest = ActiveModelSerializers::SerializableResource.new(
      status,
      serializer: REST::StatusSerializer,
      scope: viewer,
      scope_name: :current_user
    ).as_json
    activity = ActivityPub::NoteSerializer.new(status).serializable_hash
    [
      status.text,
      status.spoiler_text,
      status.media_attachments.pluck(:description),
      status.preloadable_poll&.options,
      card_bits,
      rest,
      activity,
    ].flatten.compact.join("\n")
  end

  before do
    # Link crawl resolves DNS before WebMock can see the socket. The note
    # text is what would be fetched. Projection fields are not copied into a card.
    allow(LinkCrawlWorker).to receive(:perform_async)
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(
      status: 200,
      body: '<!DOCTYPE html><html><head><title>Allowed Page</title></head><body><p>Allowed body</p></body></html>',
      headers: { 'Content-Type' => 'text/html' }
    )
  end

  after do
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
  end

  it 'keeps the link-sharing flag off and the tester list empty in settings.yml' do
    parsed = YAML.safe_load(File.read(Rails.root.join('config/settings.yml')), aliases: true)
    expect(parsed.dig('defaults', 'external_bridge_link_sharing')).to eq(false)
    expect(parsed.dig('defaults', 'external_bridge_link_sharing_testers')).to eq('')
    expect(parsed.dig('defaults', 'external_bridge_rss')).to eq(false)
    expect(parsed.dig('defaults', 'external_bridge_feeds')).to eq(false)
    expect(parsed.dig('defaults', 'external_bridge_atproto')).to eq(false)
    expect(parsed.dig('defaults', 'external_bridge_external_visibility')).to eq(false)
  end

  it 'refuses generation when the flag is off or the user is not a tester' do
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
    user = Fabricate(:user)
    world = external_project_for(user)
    grant!(user, 'public')

    expect { share!(user, world[:marker]) }.to error_code('feature_disabled')
    Setting.external_bridge_link_sharing = true
    expect { share!(user, world[:marker]) }.to error_code('tester_only')
    expect(ExternalProjectionLinkReference.where(user_id: user.id)).to be_empty
    expect(world[:status].reload.uri).to be_nil
  end

  it 'lets only the owning user create a reference note' do
    owner = Fabricate(:user)
    roommate = share_account_user(owner.account)
    stranger = Fabricate(:user)
    role = UserRole.create!(name: 'Link admin', permissions: UserRole::FLAGS[:administrator], position: 50)
    admin = Fabricate(:user, role: role)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(owner)
    plant_secrets!(world, url)
    enable_external_bridge_link_sharing!(owner, roommate, stranger, admin)
    grant!(owner, 'public')
    [roommate, stranger, admin].each { |user| grant!(user, 'public') }

    expect { share!(nil, world[:marker]) }.to error_code('not_owner')
    expect { share!(roommate, world[:marker]) }.to error_code('not_owner')
    expect { share!(stranger, world[:marker]) }.to error_code('not_owner')
    expect { share!(admin, world[:marker]) }.to error_code('not_owner')
    expect { share!(owner, world[:marker]) }.not_to raise_error
  end

  it 'gives two subscribers of one resource two reference notes' do
    left = Fabricate(:user)
    right = Fabricate(:user)
    enable_external_bridge_link_sharing!(left, right)
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml",
      title: 'Safe Feed Title',
      site_url: 'https://example.com'
    )
    resource = ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: "item:#{SecureRandom.hex(4)}",
      canonical_url: "https://example.com/posts/#{SecureRandom.hex(4)}",
      title: 'SECRET_ARTICLE_TITLE_9f3aa1',
      body: 'SECRET_BODY_9f3aa1',
      byline: 'SECRET_BYLINE_9f3aa1',
      revision: 'rev-shared'
    )
    notes = [left, right].map do |user|
      subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
      status = Status.create!(
        account: user.account,
        text: 'SECRET_PROJECTION_TEXT_9f3aa1',
        spoiler_text: 'SECRET_CW_9f3aa1',
        visibility: :external,
        searchability: :personal,
        uri: nil,
        external_projection: true,
        local: true,
        reply: false
      )
      marker = ExternalStatusProjection.create!(
        user_id: user.id,
        account_id: user.account_id,
        external_source_id: source.id,
        external_subscription_id: subscription.id,
        external_resource_id: resource.id,
        status_id: status.id,
        last_seen_revision: resource.revision
      )
      grant!(user, 'public')
      share!(user, marker).status
    end

    expect(notes.map(&:id).uniq.size).to eq(2)
    expect(notes.map(&:account_id)).to eq([left.account_id, right.account_id])
  end

  it 'composes an allowlisted note and leaves the projection private' do
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(user)
    plant_secrets!(world, url)
    projection = world[:status]
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    hooks = []
    distributions = []
    crawls = []
    allow(LinkCrawlWorker).to receive(:perform_async) { |status_id| crawls << status_id }
    allow(TriggerWebhookWorker).to receive(:perform_async).and_wrap_original do |method, *args|
      hooks << args
      method.call(*args)
    end
    allow(DistributionWorker).to receive(:perform_async).and_wrap_original do |method, *args|
      distributions << args
      method.call(*args)
    end
    allow(ActivityPub::DistributionWorker).to receive(:perform_async).and_wrap_original do |method, *args|
      distributions << args
      method.call(*args)
    end

    result = share!(user, world[:marker])
    note = result.status.reload
    projection.reload

    expect(result.created).to be(true)
    expect(note.text).to eq("Safe Feed Title\nRSS\n#{url}")
    expect(note.spoiler_text).to eq('')
    expect(note.uri).to be_present
    expect(note.visibility).to eq('public')
    expect(note.external_projection).not_to eq(true)
    expect(note.media_attachments).to be_empty
    expect(note.poll).to be_nil
    expect(note.preview_cards).to be_empty
    expect(projection.uri).to be_nil
    expect(projection.visibility).to eq('external')
    expect(projection.text).to eq('SECRET_PROJECTION_TEXT_9f3aa1')
    expect(projection.spoiler_text).to eq('SECRET_CW_9f3aa1')
    expect(ExternalStatusProjection.find_by(status_id: note.id)).to be_nil

    blob = reference_blob(note, user)
    secret_tokens.each { |token| expect(blob).not_to include(token) }
    expect(blob).to include(url)
    expect(blob).to include('Safe Feed Title')

    rest = ActiveModelSerializers::SerializableResource.new(
      projection,
      serializer: REST::StatusSerializer,
      scope: user,
      scope_name: :current_user
    ).as_json
    payload = rest[:status] || rest['status'] || rest
    expect(payload[:visibility] || payload['visibility']).to eq('direct')
    expect(payload[:visibility_ex] || payload['visibility_ex']).to eq('external')
    expect { ActivityPub::NoteSerializer.new(projection).type }.to raise_error(Status::UnreleasedActivityObject)
    expect(ActivityPub::NoteSerializer.new(note).type).to eq('Note')

    expect(hooks.map { |args| args[2] }).to include(note.id)
    expect(hooks.map { |args| args[2] }).not_to include(projection.id)
    expect(distributions.map(&:first)).to include(note.id)
    expect(distributions.map(&:first)).not_to include(projection.id)
    expect(crawls).to eq([note.id])
    home_ids = Feed.new(:home, user.account_id).get(20).map(&:id)
    expect(home_ids).to include(note.id)
    expect(home_ids).not_to include(projection.id)
    expect { ReblogService.new.call(user.account, projection) }.to raise_error(Mastodon::ValidationError)
    expect(projection.reload.visibility).to eq('external')

    again = share!(user, world[:marker])
    expect(again.created).to be(false)
    expect(again.status.id).to eq(note.id)
    expect(Status.where(account_id: user.account_id, external_projection: [false, nil]).where.not(id: projection.id).count).to eq(1)
  end

  it 'does not reuse a note across public and unlisted' do
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: url)
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'unlisted')

    expect { share!(user, world[:marker], 'public') }.to error_code('scope_rejected')
    unlisted = share!(user, world[:marker], 'unlisted')
    expect(unlisted.status.visibility).to eq('unlisted')
    ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: 'public')
    public_note = share!(user, world[:marker], 'public')
    expect(public_note.status.id).not_to eq(unlisted.status.id)
    expect(unlisted.status.reload.visibility).to eq('unlisted')
    expect(public_note.status.visibility).to eq('public')
    expect { share!(user, world[:marker], 'unlisted') }.to error_code('scope_rejected')
    expect(ExternalBridge::LinkSharing::Resolve.call(user: user, projection: world[:marker], scope: 'unlisted').id).to eq(unlisted.status.id)
  end

  it 'refuses a revoked policy and a bad canonical URL without writing a note' do
    user = Fabricate(:user)
    world = external_project_for(user)
    enable_external_bridge_link_sharing!(user)
    expect { share!(user, world[:marker]) }.to error_code('consent_required')
    grant!(user, 'public')
    ExternalBridge::LinkSharing::Policy.revoke!(user: user)
    expect { share!(user, world[:marker]) }.to error_code('consent_required')
    grant!(user, 'public')
    world[:resource].update!(canonical_url: 'https://user:pass@example.com/secret')
    expect { share!(user, world[:marker]) }.to error_code('canonical_url_invalid')
    expect(ExternalProjectionLinkReference.where(user_id: user.id)).to be_empty
  end

  it 'omits a source title that contains markup' do
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: url)
    world[:source].update!(title: '<b>Safe Feed Title</b><script>SECRET_HTML_9f3aa1</script>')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')

    note = share!(user, world[:marker]).status
    expect(note.text).to eq("RSS\n#{url}")
    expect(note.text).not_to include('SECRET_HTML_9f3aa1')
    expect(note.text).not_to include('<')
  end

  it 'keeps a published note when the canonical URL changes and does not edit it' do
    user = Fabricate(:user)
    first_url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    second_url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: first_url, revision: 'rev-1')
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    first = share!(user, world[:marker])
    world[:resource].update!(canonical_url: second_url, revision: 'rev-2')
    second = share!(user, world[:marker])

    expect(second.status.id).not_to eq(first.status.id)
    expect(first.status.reload.text).to include(first_url)
    expect(first.status.text).not_to include(second_url)
    expect(second.status.text).to include(second_url)
    expect(first.mapping.reload.state).to eq('superseded')
    expect(second.mapping.state).to eq('active')
    expect(second.mapping.resource_revision).to eq('rev-2')
  end

  it 'does not delete a published note when the source is marked deleted or the projection is purged' do
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: url)
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    note = share!(user, world[:marker]).status
    world[:marker].update!(source_deleted: true)
    again = share!(user, world[:marker])
    expect(again.status.id).to eq(note.id)

    fresh = external_project_for(user)
    fresh[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(4)}")
    fresh[:source].update!(title: 'Safe Feed Title')
    fresh[:marker].update!(source_deleted: true)
    expect { share!(user, fresh[:marker]) }.to error_code('source_deleted')
    expect(ExternalProjectionLinkReference.where(external_status_projection_id: fresh[:marker].id)).to be_empty

    ExternalBridge::ProjectionPurge.purge_subscription!(world[:subscription])
    expect(Status.find_by(id: note.id)).to be_present
    expect(note.reload.uri).to be_present
    mapping = ExternalProjectionLinkReference.find_by(reference_status_id: note.id)
    expect(mapping.external_status_projection_id).to be_nil
    expect(mapping.projection_status_id).to eq(world[:status].id)
    expect(mapping.state).to eq('active')
    expect(Status.find_by(id: world[:status].id)).to be_nil
  end

  it 'fails closed when the reference status or the mapping is missing' do
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: url)
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    result = share!(user, world[:marker])
    note = result.status
    result.mapping.delete
    expect { share!(user, world[:marker]) }.to error_code('reference_broken')
    expect(Status.find_by(id: note.id)).to be_present
    expect(ExternalProjectionLinkReference.where(user_id: user.id, state: 'active').count).to eq(0)

    replacement = ExternalProjectionLinkReference.create!(
      user_id: user.id,
      account_id: user.account_id,
      external_status_projection_id: world[:marker].id,
      projection_status_id: world[:status].id,
      reference_status_id: note.id,
      visibility: 'public',
      canonical_url: ExternalBridge::RSS::CanonicalURL.normalize!(url),
      policy_revision: user.external_link_share_policy.revision,
      state: 'active'
    )
    Status.unscoped.where(id: note.id).delete_all
    expect(replacement.reload.state).to eq('broken')
    expect(replacement.reference_status_id).to be_nil
    expect { share!(user, world[:marker]) }.to error_code('reference_broken')
    expect { ExternalBridge::LinkSharing::Resolve.call(user: user, projection: world[:marker], scope: 'public') }.to error_code('reference_broken')
  end

  it 'resolve returns nil until a note exists and then returns that note' do
    user = Fabricate(:user)
    world = external_project_for(user)
    world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(4)}")
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    expect(ExternalBridge::LinkSharing::Resolve.call(user: user, projection: world[:marker], scope: 'public')).to be_nil
    note = share!(user, world[:marker]).status
    expect(ExternalBridge::LinkSharing::Resolve.call(user: user, projection: world[:marker], scope: 'public').id).to eq(note.id)
    Setting.external_bridge_link_sharing = false
    expect { ExternalBridge::LinkSharing::Resolve.call(user: user, projection: world[:marker], scope: 'public') }.to error_code('feature_disabled')
  end

  it 'rolls the reference status back when consent changes before the mapping insert' do
    user = Fabricate(:user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    world = external_project_for(user)
    world[:resource].update!(canonical_url: url)
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    policy = grant!(user, 'public')
    captured = nil
    subscriber = ActiveSupport::Notifications.subscribe(ExternalBridge::LinkSharing::Checkpoints::EVENT) do |*args|
      payload = args.last
      next unless payload[:name] == :before_mapping_insert

      captured = payload[:extra]
      policy.update!(enabled: false, revision: policy.revision + 1)
    end

    expect { share!(user, world[:marker]) }.to error_code('consent_required')
    expect(captured).to be_present
    expect(Status.find_by(id: captured)).to be_nil
    expect(ExternalProjectionLinkReference.where(user_id: user.id)).to be_empty
    expect(policy.reload.enabled).to be(true)
    expect(world[:status].reload.uri).to be_nil
    expect(world[:status].visibility).to eq('external')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'installs link-reference triggers and rejects a mismatched owner in the database' do
    connection = ActiveRecord::Base.connection
    expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_enforce_owner' AND NOT tgisinternal")).to eq(1)
    expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_mark_broken' AND NOT tgisinternal")).to eq(1)
    expect(connection.select_value("SELECT pg_get_functiondef('users_external_projection_account_guard()'::regprocedure)")).to include('external_projection_link_references')
    expect(connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'external_projection_link_references_enforce_owner'")).to include('projection_marker_status_id')
    expect(Status.column_names).not_to include('external_projection_link_reference_id')

    owner = Fabricate(:user)
    other = Fabricate(:user)
    world = external_project_for(owner)
    note = Status.create!(account: owner.account, text: 'https://example.com/posts/db-check', visibility: :public, searchability: :public, local: true)
    snapshot = Status.create!(account: owner.account, text: 'https://example.com/posts/other-snapshot', visibility: :public, searchability: :public, local: true)
    expect_database_rejection(<<~SQL)
      INSERT INTO external_projection_link_references (
        user_id, account_id, external_status_projection_id, projection_status_id,
        reference_status_id, visibility, canonical_url, policy_revision, state, created_at, updated_at
      ) VALUES (
        #{owner.id}, #{owner.account_id}, #{world[:marker].id}, #{snapshot.id},
        #{note.id}, 'public', 'https://example.com/posts/db-check', 1, 'active', NOW(), NOW()
      )
    SQL
    expect_database_rejection(<<~SQL)
      INSERT INTO external_projection_link_references (
        user_id, account_id, external_status_projection_id, projection_status_id,
        reference_status_id, visibility, canonical_url, policy_revision, state, created_at, updated_at
      ) VALUES (
        #{other.id}, #{other.account_id}, #{world[:marker].id}, #{world[:status].id},
        #{note.id}, 'public', 'https://example.com/posts/db-check', 1, 'active', NOW(), NOW()
      )
    SQL
    moved = Fabricate(:account)
    ExternalProjectionLinkReference.create!(
      user_id: owner.id,
      account_id: owner.account_id,
      external_status_projection_id: world[:marker].id,
      projection_status_id: world[:status].id,
      reference_status_id: note.id,
      visibility: 'public',
      canonical_url: 'https://example.com/posts/db-check',
      policy_revision: 1,
      state: 'active'
    )
    expect_database_rejection("UPDATE users SET account_id = #{moved.id} WHERE id = #{owner.id}")
  end

  it 'publishes a reference once and does not republish after the redis mark expires' do
    user = Fabricate(:user)
    world = external_project_for(user)
    world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(4)}")
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    distributions = []
    allow(DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(PriorityDistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(LinkCrawlWorker).to receive(:perform_async)

    result = share!(user, world[:marker])
    note = result.status
    expect(result.mapping.reload.published_at).to be_present
    expect(distributions).to eq([note.id, note.id])

    distributions.clear
    publish = PublishStatusService.new
    publish.redis.del("statuses/#{note.id}/published")
    expect(publish.published?(note)).to be false
    again = share!(user, world[:marker])
    expect(again.status.id).to eq(note.id)
    expect(again.mapping.published_at).to eq(result.mapping.published_at)
    expect(distributions).to be_empty
    expect_database_rejection("UPDATE external_projection_link_references SET published_at = NULL WHERE id = #{result.mapping.id}")
    expect(result.mapping.reload.published_at).to be_present

    ordinary = Status.create!(account: user.account, text: 'ordinary note https://example.com/ordinary', visibility: :public, searchability: :public, local: true)
    PublishStatusService.new.call(ordinary)
    expect(distributions).to eq([ordinary.id, ordinary.id])
    distributions.clear
    publish.redis.del("statuses/#{ordinary.id}/published")
    PublishStatusService.new.call(ordinary)
    expect(distributions).to eq([ordinary.id, ordinary.id])
  end

  it 'retries distribution when publish fails before the durable mark' do
    user = Fabricate(:user)
    world = external_project_for(user)
    world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(4)}")
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    distributions = []
    allow(DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(PriorityDistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(LinkCrawlWorker).to receive(:perform_async)
    subscriber = ActiveSupport::Notifications.subscribe(ExternalBridge::LinkSharing::Checkpoints::EVENT) do |*args|
      payload = args.last
      raise 'publish interrupted' if payload[:name] == :before_reference_publish
    end

    expect { share!(user, world[:marker]) }.to raise_error(RuntimeError, 'publish interrupted')
    mapping = ExternalProjectionLinkReference.find_by!(user_id: user.id, state: 'active')
    expect(mapping.published_at).to be_nil
    expect(mapping.reference_status_id).to be_present
    expect(distributions).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    if mapping
      ExternalBridge::LinkReferencePublishWorker.new.perform(mapping.id)
      published = mapping.reload
      expect(published.published_at).to be_present
      expect(distributions).to eq([published.reference_status_id, published.reference_status_id])
      distributions.clear
      PublishStatusService.new.redis.del("statuses/#{published.reference_status_id}/published")
      ExternalBridge::LinkReferencePublishWorker.new.perform(mapping.id)
      expect(distributions).to be_empty
    end
  end

  it 'shares a public permalink query that the feed normalizer rejects' do
    user = Fabricate(:user)
    suffix = SecureRandom.hex(4)
    world = external_project_for(user)
    world[:resource].update!(canonical_url: "https://example.com/posts/#{suffix}?p=123")
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')

    note = share!(user, world[:marker]).status
    expect(note.text).to eq("Safe Feed Title\nRSS\nhttps://example.com/posts/#{suffix}?p=123")
    expect { ExternalBridge::RSS::CanonicalURL.normalize!(world[:resource].reload.canonical_url) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq('authenticated_source_rejected') }
  end

  it 'recovers a committed unpublished note without another ensure' do
    user = Fabricate(:user)
    world = external_project_for(user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    note = Status.create!(
      account: user.account,
      text: "Safe Feed Title\nRSS\n#{url}",
      visibility: :public,
      searchability: :public,
      local: true,
      external_projection: false
    )
    mapping = ExternalProjectionLinkReference.create!(
      user_id: user.id,
      account_id: user.account_id,
      external_status_projection_id: world[:marker].id,
      projection_status_id: world[:status].id,
      reference_status_id: note.id,
      visibility: 'public',
      canonical_url: url,
      policy_revision: 1,
      state: 'active'
    )
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
    distributions = []
    allow(DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(PriorityDistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(LinkCrawlWorker).to receive(:perform_async)

    expect(Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform).to eq(1)
    expect(mapping.reload.published_at).to be_present
    expect(distributions).to eq([note.id, note.id])
    distributions.clear
    PublishStatusService.new.redis.del("statuses/#{note.id}/published")
    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(0)
    expect(distributions).to be_empty
  end

  it 'does not recover a broken mapping and retries when enqueue is refused' do
    user = Fabricate(:user)
    world = external_project_for(user)
    url = "https://example.com/posts/#{SecureRandom.hex(4)}"
    note = Status.create!(
      account: user.account,
      text: "Safe Feed Title\nRSS\n#{url}",
      visibility: :public,
      searchability: :public,
      local: true,
      external_projection: false
    )
    mapping = ExternalProjectionLinkReference.create!(
      user_id: user.id,
      account_id: user.account_id,
      external_status_projection_id: world[:marker].id,
      projection_status_id: world[:status].id,
      reference_status_id: note.id,
      visibility: 'public',
      canonical_url: url,
      policy_revision: 1,
      state: 'active'
    )
    mapping.update!(state: 'broken')
    allow(LinkCrawlWorker).to receive(:perform_async)
    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(0)
    expect(mapping.reload.published_at).to be_nil

    second = Status.create!(
      account: user.account,
      text: 'https://example.com/posts/second-note',
      visibility: :public,
      searchability: :public,
      local: true,
      external_projection: false
    )
    pending = ExternalProjectionLinkReference.create!(
      user_id: user.id,
      account_id: user.account_id,
      external_status_projection_id: nil,
      projection_status_id: world[:status].id,
      reference_status_id: second.id,
      visibility: 'public',
      canonical_url: 'https://example.com/posts/second-note',
      policy_revision: 1,
      state: 'active'
    )
    allow(ExternalBridge::LinkReferencePublishWorker).to receive(:perform_async).and_return(nil)
    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(1)
    expect(pending.reload.published_at).to be_nil

    distributions = []
    allow(ExternalBridge::LinkReferencePublishWorker).to receive(:perform_async).and_call_original
    allow(DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    allow(PriorityDistributionWorker).to receive(:perform_async) { |status_id, *| distributions << status_id }
    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(1)
    expect(pending.reload.published_at).to be_present
    expect(distributions).to eq([second.id, second.id])
    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(0)
  end

  it 'reaches later unpublished rows while the oldest batch is refused' do
    user = Fabricate(:user)
    world = external_project_for(user)
    suffix = SecureRandom.hex(4)
    mappings = Array.new(30) do |index|
      plant_unpublished_reference!(user, world, "https://example.com/posts/#{suffix}-#{index}")
    end
    ids = mappings.map(&:id).sort
    low = ids.first(ExternalBridge::LinkSharing::RecoverUnpublished::BATCH)
    high = ids.drop(ExternalBridge::LinkSharing::RecoverUnpublished::BATCH)
    enqueued = []
    allow(ExternalBridge::LinkReferencePublishWorker).to receive(:perform_async) do |id|
      enqueued << id
      low.include?(id) ? nil : "jid-#{id}"
    end

    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(20)
    expect(enqueued).to eq(low)

    enqueued.clear
    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(20)
    expect(enqueued.first(high.size)).to eq(high)
    high.each do |id|
      expect(ExternalProjectionLinkReference.find(id).next_recovery_at).to be > Time.current
      expect(ExternalProjectionLinkReference.find(id).published_at).to be_nil
    end

    enqueued.clear
    expect(ExternalBridge::LinkSharing::RecoverUnpublished.call).to eq(20)
    expect(enqueued & high).to be_empty
  end

  it 'does not push another job for an accepted row on the next scheduler passes' do
    user = Fabricate(:user)
    world = external_project_for(user)
    mapping = plant_unpublished_reference!(user, world, "https://example.com/posts/#{SecureRandom.hex(4)}")
    Sidekiq::Testing.fake! do
      ExternalBridge::LinkReferencePublishWorker.clear
      expect(Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform).to eq(1)
      3.times do
        expect(Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform).to eq(0)
      end
      expect(ExternalBridge::LinkReferencePublishWorker.jobs.map { |job| job['args'] }).to eq([[mapping.id]])
      expect(mapping.reload.published_at).to be_nil
      expect(mapping.next_recovery_at).to be > 20.minutes.from_now

      mapping.update_columns(next_recovery_at: 1.minute.ago)
      expect(Scheduler::ExternalBridgeLinkReferencePublishScheduler.new.perform).to eq(1)
      expect(ExternalBridge::LinkReferencePublishWorker.jobs.size).to eq(2)
    end
  ensure
    Sidekiq::Testing.inline!
  end

  it 'uses the unpublished recovery index for the bounded scan' do
    connection = ActiveRecord::Base.connection
    indexdef = connection.select_value("SELECT indexdef FROM pg_indexes WHERE indexname = 'index_link_refs_on_unpublished_recovery'")
    expect(indexdef).to include('next_recovery_at')
    expect(indexdef).to include('NULLS FIRST')
    expect(indexdef).to include('published_at IS NULL')

    plan = connection.transaction do
      connection.execute('SET LOCAL enable_seqscan = off')
      connection.select_values(<<~SQL).join("\n")
        EXPLAIN
        SELECT external_projection_link_references.id
        FROM external_projection_link_references
        WHERE published_at IS NULL
          AND state IN ('active', 'superseded')
          AND reference_status_id IS NOT NULL
          AND (next_recovery_at IS NULL OR next_recovery_at <= NOW())
        ORDER BY next_recovery_at ASC NULLS FIRST, external_projection_link_references.id
        LIMIT 20
      SQL
    end
    expect(plan).to include('index_link_refs_on_unpublished_recovery')
  end

  it 'rolls link sharing down and back up on an empty database' do
    expect(ExternalProjectionLinkReference.count).to eq(0)
    expect(ExternalLinkSharePolicy.count).to eq(0)
    connection = ActiveRecord::Base.connection
    ActiveRecord::Base.transaction(requires_new: true) do
      AddExternalLinkReferenceNextRecoveryAt.new.down
      AddExternalLinkReferencePublishedAt.new.down
      CreateExternalLinkSharing.new.down
      expect(connection.table_exists?(:external_projection_link_references)).to be false
      CreateExternalLinkSharing.new.up
      AddExternalLinkReferencePublishedAt.new.up
      AddExternalLinkReferenceNextRecoveryAt.new.up
      expect(connection.column_exists?(:external_projection_link_references, :published_at)).to be true
      expect(connection.column_exists?(:external_projection_link_references, :next_recovery_at)).to be true
      expect(connection.select_value("SELECT indexdef FROM pg_indexes WHERE indexname = 'index_link_refs_on_unpublished_recovery'")).to include('NULLS FIRST')
      expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_enforce_owner' AND NOT tgisinternal")).to eq(1)
      expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_publish_mark' AND NOT tgisinternal")).to eq(1)
      expect(connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'external_projection_link_references_enforce_owner'")).to include('projection_marker_status_id')
      raise ActiveRecord::Rollback
    end
    expect(connection.table_exists?(:external_projection_link_references)).to be true
    expect(connection.column_exists?(:external_projection_link_references, :published_at)).to be true
    expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_mark_broken' AND NOT tgisinternal")).to eq(1)
  end

  it 'refuses to roll back while a mapping and a reference note exist' do
    user = Fabricate(:user)
    world = external_project_for(user)
    world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(4)}")
    world[:source].update!(title: 'Safe Feed Title')
    enable_external_bridge_link_sharing!(user)
    grant!(user, 'public')
    result = share!(user, world[:marker])
    note = result.status
    mapping = result.mapping
    connection = ActiveRecord::Base.connection

    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        AddExternalLinkReferencePublishedAt.new.down
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /reference mapping exists/)

    expect(mapping.reload.published_at).to be_present
    expect(mapping.reference_status_id).to eq(note.id)
    expect(Status.find(note.id).text).to include('https://')
    expect(user.reload.external_link_share_policy).to be_present
    expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_enforce_owner' AND NOT tgisinternal")).to eq(1)
    expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_publish_mark' AND NOT tgisinternal")).to eq(1)
    expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_projection_link_references_mark_broken' AND NOT tgisinternal")).to eq(1)

    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        CreateExternalLinkSharing.new.down
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /reference mapping exists/)
    expect(ExternalProjectionLinkReference.find(mapping.id).reference_status_id).to eq(note.id)
    expect(Status.find(note.id)).to be_present
  end
end

# rubocop:enable Metrics/BlockLength
