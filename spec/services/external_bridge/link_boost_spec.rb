# frozen_string_literal: true

# E4-B state contract. The examples share one world builder, so they stay in
# one file the way the E4-A matrix does.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe 'ExternalBridge link boost', type: :model do
  def secret_tokens
    %w(
      SECRET_BODY_b1c0de
      SECRET_PROJECTION_TEXT_b1c0de
      SECRET_CW_b1c0de
      SECRET_ARTICLE_TITLE_b1c0de
    )
  end

  def error_code(code)
    raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq(code) }
  end

  def grant!(user, visibility = 'public')
    ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: visibility)
  end

  def prepare(user, visibility: 'public', url: "https://example.com/posts/#{SecureRandom.hex(5)}")
    world = external_project_for(user, body: 'SECRET_BODY_b1c0de')
    world[:source].update!(title: 'Safe Feed Title')
    world[:resource].update!(canonical_url: url, title: 'SECRET_ARTICLE_TITLE_b1c0de')
    world[:status].update_columns(text: 'SECRET_PROJECTION_TEXT_b1c0de', spoiler_text: 'SECRET_CW_b1c0de')
    enable_external_bridge_link_sharing!(user)
    grant!(user, visibility)
    world.merge(url: url)
  end

  def boost!(user, world, **options)
    ExternalBridge::LinkSharing::Boost.call(user: user, status: world[:status], **options)
  end

  def unboost!(user, world)
    ExternalBridge::LinkSharing::Unboost.call(user: user, status: world[:status])
  end

  def rows_for(world)
    ExternalProjectionLinkBoost.where(projection_status_id: world[:status].id).order(:id)
  end

  def sole_row(world)
    rows = rows_for(world).to_a
    expect(rows.size).to eq(1)
    rows.first
  end

  def gone?(status_id)
    status = Status.unscoped.find_by(id: status_id)
    status.nil? || status.deleted_at.present?
  end

  def serialized(status, viewer)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        status,
        serializer: REST::StatusSerializer,
        scope: viewer,
        scope_name: :current_user
      ).to_json
    ).deep_symbolize_keys
  end

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(status: 200, body: '<html><head><title>x</title></head></html>', headers: { 'Content-Type' => 'text/html' })
  end

  after do
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
  end

  it 'turns a boost of the projection into one wrapper of the own link note' do
    user = Fabricate(:user)
    world = prepare(user)
    hooks = []
    allow(TriggerWebhookWorker).to receive(:perform_async).and_wrap_original do |method, *args|
      hooks << args
      method.call(*args)
    end

    result = boost!(user, world)
    projection = world[:status].reload
    reference = result.reference.reload
    wrapper = result.wrapper.reload

    expect(result.created).to be(true)
    expect(wrapper.reblog_of_id).to eq(reference.id)
    expect(wrapper.account_id).to eq(user.account_id)
    expect(wrapper.visibility).to eq('public')
    expect(wrapper.text).to eq('')
    expect(reference.text).to eq("Safe Feed Title\nRSS\n#{world[:url]}")
    expect(reference.external_projection).not_to eq(true)
    expect(projection.visibility).to eq('external')
    expect(projection.reblogs_count).to eq(0)
    expect(Status.where(reblog_of_id: projection.id)).to be_empty

    row = sole_row(world)
    expect(row.user_id).to eq(user.id)
    expect(row.state).to eq('active')
    expect(row.generation).to eq(1)
    expect(row.link_reference_id).to eq(result.boost.link_reference_id)
    expect(row.announced_at).to be_present
    expect(row.wrapper_status_id).to eq(wrapper.id)
    expect(row.reference_status_id).to eq(reference.id)

    json = serialized(wrapper, user).to_json
    secret_tokens.each { |token| expect(json).not_to include(token) }
    expect(json).not_to include(projection.id.to_s) if projection.id.to_s.length > 8
    expect(serialized(wrapper, user)[:reblog][:id]).to eq(reference.id.to_s)

    activity = ActivityPub::ActivityPresenter.from_status(wrapper)
    payload = ActiveModelSerializers::SerializableResource.new(activity, serializer: ActivityPub::ActivitySerializer, adapter: ActivityPub::Adapter).to_json
    secret_tokens.each { |token| expect(payload).not_to include(token) }
    expect(payload).to include(ActivityPub::TagManager.instance.uri_for(reference))
    expect(hooks.map { |args| args[2] }).not_to include(projection.id)
  end

  it 'is repeatable and does not duplicate wrappers or boost rows' do
    user = Fabricate(:user)
    world = prepare(user)

    first = boost!(user, world)
    second = boost!(user, world)

    expect(second.created).to be(false)
    expect(second.wrapper.id).to eq(first.wrapper.id)
    expect(rows_for(world).count).to eq(1)
    expect(Status.where(reblog_of_id: first.reference.id).count).to eq(1)
    expect(ExternalProjectionLinkReference.where(user_id: user.id).count).to eq(1)
  end

  it 'undoes only the wrapper, keeps the note and the projection, and is idempotent' do
    user = Fabricate(:user)
    world = prepare(user)
    result = boost!(user, world)
    Favourite.create!(account: user.account, status: world[:status])
    Bookmark.create!(account: user.account, status: world[:status])
    removals = []
    allow(RemovalWorker).to receive(:perform_async).and_wrap_original do |method, *args|
      removals << args.first
      method.call(*args)
    end

    first = unboost!(user, world)
    second = unboost!(user, world)

    expect(first.ended).to eq(1)
    expect(second.ended).to eq(0)
    expect(removals).to eq([result.wrapper.id])
    expect(gone?(result.wrapper.id)).to be(true)
    expect(Status.find(result.reference.id).deleted_at).to be_nil
    expect(Status.find(world[:status].id).visibility).to eq('external')
    expect(Favourite.where(account_id: user.account_id, status_id: world[:status].id)).to exist
    expect(Bookmark.where(account_id: user.account_id, status_id: world[:status].id)).to exist
    expect(sole_row(world).state).to eq('undone')
    expect(sole_row(world).ended_reason).to eq('user_undo')
    expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(false)
  end

  it 'shares again after an undo with a new generation and a new wrapper' do
    user = Fabricate(:user)
    world = prepare(user)
    first = boost!(user, world)
    unboost!(user, world)
    second = boost!(user, world)

    expect(second.created).to be(true)
    expect(second.reference.id).to eq(first.reference.id)
    expect(second.wrapper.id).not_to eq(first.wrapper.id)
    expect(rows_for(world).pluck(:generation, :state)).to eq([[1, 'undone'], [2, 'active']])
    expect(Status.find(first.reference.id).reblogs_count).to be >= 1
    expect(ExternalProjectionLinkReference.where(user_id: user.id).count).to eq(1)
  end

  it 'keeps users of the same account apart' do
    owner = Fabricate(:user)
    roommate = share_account_user(owner.account)
    stranger = Fabricate(:user)
    role = UserRole.create!(name: 'Boost admin', permissions: UserRole::FLAGS[:administrator], position: 50)
    admin = Fabricate(:user, role: role)
    world = prepare(owner)
    enable_external_bridge_link_sharing!(owner, roommate, stranger, admin)
    [roommate, stranger, admin].each { |user| grant!(user, 'public') }

    [nil, roommate, stranger, admin].each do |user|
      expect { boost!(user, world) }.to error_code('not_owner')
      expect { unboost!(user, world) }.to error_code('not_owner')
    end
    expect(ExternalProjectionLinkBoost.count).to eq(0)

    boost!(owner, world)

    expect(ExternalBridge::LinkSharing::BoostState.active?(owner, world[:status])).to be(true)
    expect(ExternalBridge::LinkSharing::BoostState.active?(roommate, world[:status])).to be(false)
    expect(ExternalBridge::LinkSharing::BoostState.active?(stranger, world[:status])).to be(false)
    expect(ExternalBridge::LinkSharing::BoostState.active?(nil, world[:status])).to be(false)
    expect { unboost!(roommate, world) }.to error_code('not_owner')
    expect(sole_row(world).state).to eq('active')

    roommate_world = prepare(roommate)
    expect(account_reblogged?(roommate.account, world)).to be(true)
    expect(ExternalBridge::LinkSharing::BoostState.active?(roommate, world[:status])).to be(false)
    other = boost!(roommate, roommate_world)
    expect(other.wrapper.reblog_of_id).not_to eq(sole_row(world).reference_status_id)
    expect { unboost!(roommate, roommate_world) }.not_to raise_error
    expect(sole_row(world).state).to eq('active')
  end

  def account_reblogged?(account, world)
    ExternalProjectionLinkBoost.find_by(projection_status_id: world[:status].id).present? &&
      Status.where(account_id: account.id, reblog_of_id: ExternalProjectionLinkBoost.find_by(projection_status_id: world[:status].id).reference_status_id).exists?
  end

  it 'refuses a forged marker, a legacy status, and a flag-only status' do
    user = Fabricate(:user)
    world = prepare(user)

    legacy = Status.create!(account: user.account, text: 'legacy', visibility: :personal, searchability: :personal, local: true)
    flagged = Status.create!(account: user.account, text: 'flag', visibility: :public, local: true)
    flagged.update_columns(external_projection: true)

    [legacy, flagged].each do |status|
      expect { ExternalBridge::LinkSharing::Boost.call(user: user, status: status) }.to error_code('not_owner')
    end
    expect(ExternalProjectionLinkBoost.count).to eq(0)
    expect(world[:marker].user_id).to eq(user.id)
  end

  it 'does not create anything while the flag is off, the user is not a tester, or consent is missing' do
    user = Fabricate(:user)
    world = prepare(user)

    Setting.external_bridge_link_sharing = false
    expect { boost!(user, world) }.to error_code('feature_disabled')
    Setting.external_bridge_link_sharing = true
    Setting.external_bridge_link_sharing_testers = ''
    expect { boost!(user, world) }.to error_code('tester_only')
    enable_external_bridge_link_sharing!(user)
    ExternalBridge::LinkSharing::Policy.revoke!(user: user)
    expect { boost!(user, world) }.to error_code('consent_required')

    expect(ExternalProjectionLinkBoost.count).to eq(0)
    expect(ExternalProjectionLinkReference.count).to eq(0)
    expect(Status.where(account_id: user.account_id, external_projection: [false, nil]).count).to eq(0)
  end

  it 'lets a live share be undone after the flag goes off and consent is revoked' do
    user = Fabricate(:user)
    world = prepare(user)
    boost!(user, world)

    ExternalBridge::LinkSharing::Policy.revoke!(user: user)
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''

    expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(true)
    expect(unboost!(user, world).ended).to eq(1)
    expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(false)
  end

  it 'never widens the consented scope from request parameters' do
    user = Fabricate(:user)
    world = prepare(user, visibility: 'unlisted')

    %w(public private direct limited mutual personal).each do |value|
      expect { boost!(user, world, visibility: value) }.to error_code('visibility_mismatch')
    end
    expect { boost!(user, world, circle_id: '12') }.to error_code('circle_rejected')
    expect(ExternalProjectionLinkBoost.count).to eq(0)
    expect(ExternalProjectionLinkReference.count).to eq(0)

    result = boost!(user, world, visibility: 'unlisted')
    expect(result.wrapper.visibility).to eq('unlisted')
    expect(result.reference.visibility).to eq('unlisted')
  end

  it 'rejects the raw projection in the ordinary boost service' do
    user = Fabricate(:user)
    world = prepare(user)

    expect { ReblogService.new.call(user.account, world[:status]) }.to raise_error(Mastodon::ValidationError)
    expect(StatusPolicy.new(user.account, world[:status]).reblog?).to be(false)
    expect(Status.where(reblog_of_id: world[:status].id)).to be_empty
  end

  describe 'Create then Announce' do
    it 'announces only after the reference Create is distributed and never touches local timelines' do
      user = Fabricate(:user, current_sign_in_at: Time.current)
      follower = Fabricate(:user, current_sign_in_at: Time.current)
      follower.account.follow!(user.account)
      world = prepare(user)
      calls = []
      allow(DistributionWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        calls << [:local, args.first]
        method.call(*args)
      end
      allow(ActivityPub::DistributionWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        calls << [:ap, args.first]
        method.call(*args)
      end

      result = nil
      Sidekiq::Testing.fake! do
        result = boost!(user, world)
        row = sole_row(world)
        expect(row.announced_at).to be_nil
        expect(calls).to be_empty
        expect(ExternalBridge::LinkBoostAnnounceWorker.jobs).to be_empty

        ExternalBridge::LinkBoostAnnounceWorker.new.perform(row.id)
        expect(calls).to be_empty
        expect(row.reload.announced_at).to be_nil

        ExternalBridge::LinkReferencePublishWorker.drain
        expect(calls).to eq([[:local, result.reference.id], [:ap, result.reference.id]])
        expect(ExternalBridge::LinkBoostAnnounceWorker.jobs.size).to eq(1)

        ExternalBridge::LinkBoostAnnounceWorker.drain
        ExternalBridge::LinkBoostAnnounceWorker.new.perform(row.id)
        [DistributionWorker, FeedInsertWorker, PriorityFeedInsertWorker, ActivityPub::DistributionWorker].each(&:drain)
      end
      Sidekiq::Testing.inline!

      expect(calls).to eq([[:local, result.reference.id], [:ap, result.reference.id], [:ap, result.wrapper.id]])
      expect(sole_row(world).announced_at).to be_present
      [user, follower].each do |viewer|
        ids = Feed.new(:home, viewer.account_id).get(20).map(&:id)
        expect(ids).to include(result.reference.id)
        expect(ids).not_to include(result.wrapper.id)
      end
    end

    it 'keeps the wrapper out of rebuilt feeds and the profile listing' do
      user = Fabricate(:user, current_sign_in_at: Time.current)
      follower = Fabricate(:user, current_sign_in_at: Time.current)
      follower.account.follow!(user.account)
      aggregator = Fabricate(:user, current_sign_in_at: Time.current)
      aggregator.account.follow!(user.account)
      aggregator.settings['aggregate_reblogs'] = false
      aggregator.save!
      world = prepare(user)
      result = boost!(user, world)
      expect(Status.where(id: result.wrapper.id)).to exist

      [user, follower, aggregator].each do |viewer|
        redis.del(FeedManager.instance.key(:home, viewer.account_id))
        FeedManager.instance.populate_home(viewer.account)
        ids = Feed.new(:home, viewer.account_id).get(20).map(&:id)
        expect(ids).to include(result.reference.id)
        expect(ids).not_to include(result.wrapper.id)
      end

      redis.del(FeedManager.instance.key(:home, follower.account_id))
      FeedManager.instance.merge_into_home(user.account, follower.account)
      ids = Feed.new(:home, follower.account_id).get(20).map(&:id)
      expect(ids).to include(result.reference.id)
      expect(ids).not_to include(result.wrapper.id)

      profile = AccountStatusesFeed.new(user.account, follower.account).relation.pluck(:id)
      expect(profile).to include(result.reference.id)
      expect(profile).not_to include(result.wrapper.id)
      expect(AccountStatusesFeed.new(user.account, user.account).relation.pluck(:id)).not_to include(result.wrapper.id)
    end

    it 'announces at once when the reference Create already went out' do
      user = Fabricate(:user)
      world = prepare(user)
      first = boost!(user, world)
      unboost!(user, world)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        calls << args.first
        method.call(*args)
      end

      second = boost!(user, world)

      expect(calls).to eq([second.wrapper.id])
      expect(second.wrapper.id).not_to eq(first.wrapper.id)
    end

    it 'does not announce a share that was undone before its job ran' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
      removals = []
      allow(RemovalWorker).to receive(:perform_async) { |id| removals << id }
      wrapper_id = nil

      Sidekiq::Testing.fake! do
        result = boost!(user, world)
        wrapper_id = result.wrapper.id
        unboost!(user, world)
        ExternalBridge::LinkReferencePublishWorker.drain
        ExternalBridge::LinkBoostAnnounceWorker.drain
        row = sole_row(world)
        ExternalBridge::LinkBoostAnnounceWorker.new.perform(row.id)

        expect(row.reload.state).to eq('undone')
        expect(row.announced_at).to be_nil
        expect(gone?(wrapper_id)).to be(true)
      end
      Sidekiq::Testing.inline!

      expect(calls).not_to include(wrapper_id)
      expect(removals).to be_empty
    end

    it 'closes a pending share instead of announcing when consent, scope, or the flag changed' do
      %i(revoke scope flag).each do |change|
        user = Fabricate(:user)
        world = prepare(user)
        calls = []
        allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
        wrapper = nil

        Sidekiq::Testing.fake! do
          wrapper = boost!(user, world).wrapper
          case change
          when :revoke then ExternalBridge::LinkSharing::Policy.revoke!(user: user)
          when :scope then ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: 'unlisted')
          else Setting.external_bridge_link_sharing = false
          end
          ExternalBridge::LinkReferencePublishWorker.drain
          ExternalBridge::LinkBoostAnnounceWorker.drain
        end
        Sidekiq::Testing.inline!
        Setting.external_bridge_link_sharing = true

        row = sole_row(world)
        expect(row.state).to eq('undone'), "#{change} should close the row"
        expect(row.ended_reason).to eq('consent_withdrawn')
        expect(calls).not_to include(wrapper.id)
        expect(gone?(wrapper.id)).to be(true)
      end
    end

    it 'is idempotent under repeated and concurrent announce jobs' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        calls << args.first
        method.call(*args)
      end
      result = boost!(user, world)
      row = sole_row(world)

      3.times { ExternalBridge::LinkBoostAnnounceWorker.new.perform(row.id) }

      expect(calls.count(result.wrapper.id)).to eq(1)
      expect(ExternalBridge::LinkSharing::BoostAnnounce.call(row.id)).to eq(:announced)
    end

    it 'recovers an announce whose job was never accepted, only after the Create is out' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        calls << args.first
        method.call(*args)
      end

      result = nil
      Sidekiq::Testing.fake! do
        result = boost!(user, world)
        expect(ExternalBridge::LinkSharing::RecoverUnannounced.call).to eq(0)
        ExternalBridge::LinkReferencePublishWorker.drain
        ExternalBridge::LinkBoostAnnounceWorker.clear
        expect(ExternalBridge::LinkSharing::RecoverUnannounced.call).to eq(1)
        expect(ExternalBridge::LinkBoostAnnounceWorker.jobs.size).to eq(1)
        expect(ExternalBridge::LinkSharing::RecoverUnannounced.call).to eq(0)
        ExternalBridge::LinkBoostAnnounceWorker.drain
      end
      Sidekiq::Testing.inline!

      expect(calls).to include(result.wrapper.id)
    end
  end

  describe 'the reference note' do
    it 'refuses a note that was edited into something else' do
      edits = {
        'added text' => ->(note) { note.update_columns(text: "#{note.text}\nI also added my own opinion") },
        'warning' => ->(note) { note.update_columns(spoiler_text: 'CW') },
        'sensitive' => ->(note) { note.update_columns(sensitive: true) },
        'media' => lambda { |note|
          MediaAttachment.insert!({ account_id: note.account_id, status_id: note.id, remote_url: '', type: 0, created_at: Time.current, updated_at: Time.current })
        },
        'reply' => ->(note) { note.update_columns(in_reply_to_id: Fabricate(:status).id) },
        'quote' => ->(note) { note.update_columns(quote_id: Fabricate(:status).id) },
      }

      edits.each do |label, edit|
        user = Fabricate(:user)
        world = prepare(user)
        reference = boost!(user, world).reference
        unboost!(user, world)
        edit.call(reference)

        expect { boost!(user, world) }.to error_code('reference_modified'), label
        expect(rows_for(world).where(state: 'active')).to be_empty, label
      end
    end

    it 'accepts a revert and does not mind a changed source title' do
      user = Fabricate(:user)
      world = prepare(user)
      reference = boost!(user, world).reference
      unboost!(user, world)
      original = reference.text
      reference.update_columns(text: "#{original} extra")
      expect { boost!(user, world) }.to error_code('reference_modified')
      reference.update_columns(text: original)
      world[:source].update!(title: 'Renamed Feed Title')

      expect(boost!(user, world).wrapper.reblog_of_id).to eq(reference.id)
    end

    it 'refuses an unpublished share of a note that was deleted' do
      user = Fabricate(:user)
      world = prepare(user)
      reference = boost!(user, world).reference
      unboost!(user, world)
      reference.discard

      expect { boost!(user, world) }.to error_code('reference_broken')
      expect(rows_for(world).where(state: 'active')).to be_empty
    end

    it 'closes the share when the note is hard-deleted' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      Status.where(id: result.reference.id).delete_all

      row = sole_row(world).reload
      expect(row.state).to eq('undone')
      expect(row.ended_reason).to eq('status_deleted')
      expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(false)
    end

    it 'does not adopt an ordinary boost of the note that this table does not know' do
      user = Fabricate(:user)
      world = prepare(user)
      reference = boost!(user, world).reference
      unboost!(user, world)
      ordinary = Status.create!(account: user.account, reblog: reference, text: '', visibility: :public)

      expect { boost!(user, world) }.to error_code('reference_already_boosted')
      expect(Status.find(ordinary.id).deleted_at).to be_nil
      expect(rows_for(world).where(state: 'active')).to be_empty
    end

    it 'does not take an ordinary boost of the note for the share of a user' do
      user = Fabricate(:user)
      roommate = share_account_user(user.account)
      world = prepare(user)
      reference = boost!(user, world).reference

      expect(Status.where(account_id: user.account_id, reblog_of_id: reference.id)).to exist
      expect(ExternalBridge::LinkSharing::BoostState.active?(roommate, world[:status])).to be(false)
      expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(true)
    end

    it 'treats a wrapper discarded elsewhere as no share and shares again' do
      user = Fabricate(:user)
      world = prepare(user)
      first = boost!(user, world)
      first.wrapper.discard

      expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(false)
      expect { boost!(user, world) }.to error_code('reference_conflict')
      first.wrapper.destroy!
      second = boost!(user, world)
      expect(second.created).to be(true)
      expect(rows_for(world).pluck(:state)).to eq(%w(undone active))
    end
  end

  describe 'a live share that no longer matches the request' do
    it 'refuses a new scope without creating a note and without widening the old share' do
      [%w(unlisted public), %w(public unlisted)].each do |from, to|
        user = Fabricate(:user)
        world = prepare(user, visibility: from)
        first = boost!(user, world)
        mapping_ids = ExternalProjectionLinkReference.where(user_id: user.id).pluck(:id)
        note_count = Status.where(account_id: user.account_id, external_projection: [false, nil]).count
        ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: to)

        expect { boost!(user, world) }.to error_code('share_outdated'), "#{from} to #{to}"

        expect(ExternalProjectionLinkReference.where(user_id: user.id).pluck(:id)).to eq(mapping_ids)
        expect(Status.where(account_id: user.account_id, external_projection: [false, nil]).count).to eq(note_count)
        expect(rows_for(world).pluck(:state, :visibility, :wrapper_status_id)).to eq([['active', from, first.wrapper.id]])
        expect(Status.find(first.wrapper.id).visibility).to eq(from)
      end
    end

    it 'moves to the new scope only through an explicit undo, with Undo for an announced share' do
      user = Fabricate(:user)
      world = prepare(user, visibility: 'unlisted')
      first = boost!(user, world)
      removals = []
      allow(RemovalWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        removals << args.first
        method.call(*args)
      end
      ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: 'public')
      expect { boost!(user, world) }.to error_code('share_outdated')

      unboost!(user, world)
      second = boost!(user, world)

      expect(removals).to eq([first.wrapper.id])
      expect(second.created).to be(true)
      expect(second.reference.id).not_to eq(first.reference.id)
      expect(second.reference.visibility).to eq('public')
      expect(second.wrapper.visibility).to eq('public')
      expect(second.wrapper.reblog_of_id).to eq(second.reference.id)
      expect(rows_for(world).pluck(:state, :visibility)).to eq([%w(undone unlisted), %w(active public)])
      expect(ExternalProjectionLinkReference.where(user_id: user.id, state: 'active').count).to eq(2)
    end

    it 'does the same for a share that was never announced, and sends no Undo' do
      user = Fabricate(:user)
      world = prepare(user, visibility: 'public')
      removals = []
      allow(RemovalWorker).to receive(:perform_async) { |id| removals << id }
      wrapper = nil
      Sidekiq::Testing.fake! do
        wrapper = boost!(user, world).wrapper
        expect(sole_row(world).announced_at).to be_nil
        ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: 'unlisted')
        expect { boost!(user, world) }.to error_code('share_outdated')
        unboost!(user, world)
        expect(gone?(wrapper.id)).to be(true)
        again = boost!(user, world)
        expect(again.wrapper.visibility).to eq('unlisted')
        expect(again.reference.visibility).to eq('unlisted')
      end
      Sidekiq::Testing.inline!

      expect(removals).to be_empty
    end

    it 'refuses a changed canonical URL, and ignores a changed source title' do
      user = Fabricate(:user)
      world = prepare(user)
      first = boost!(user, world)

      world[:source].update!(title: 'Renamed Feed Title')
      same = boost!(user, world)
      expect(same.created).to be(false)
      expect(same.wrapper.id).to eq(first.wrapper.id)

      world[:resource].update!(canonical_url: "#{world[:url]}-moved")
      mapping_ids = ExternalProjectionLinkReference.where(user_id: user.id).pluck(:id)
      expect { boost!(user, world) }.to error_code('share_outdated')
      expect(ExternalProjectionLinkReference.where(user_id: user.id).pluck(:id)).to eq(mapping_ids)
      expect(Status.where(account_id: user.account_id, external_projection: [false, nil]).count).to eq(2)
      expect(sole_row(world).state).to eq('active')

      unboost!(user, world)
      moved = boost!(user, world)
      expect(moved.reference.text).to include('-moved')
      expect(moved.reference.id).not_to eq(first.reference.id)
      expect(ExternalProjectionLinkReference.find(first.boost.link_reference_id).state).to eq('superseded')
    end

    it 'closes an unannounced share at announce time when the URL moved' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
      wrapper = nil
      Sidekiq::Testing.fake! do
        wrapper = boost!(user, world).wrapper
        world[:resource].update!(canonical_url: "#{world[:url]}-moved")
        ExternalBridge::LinkReferencePublishWorker.drain
        ExternalBridge::LinkBoostAnnounceWorker.drain
      end
      Sidekiq::Testing.inline!

      expect(sole_row(world).ended_reason).to eq('reference_unavailable')
      expect(calls).not_to include(wrapper.id)
    end

    it 'refuses a live share whose old note was edited, and ends it when the note is deleted' do
      user = Fabricate(:user)
      world = prepare(user)
      first = boost!(user, world)
      first.reference.update_columns(text: "#{first.reference.text}\nedited")

      expect { boost!(user, world) }.to error_code('reference_modified')
      expect(sole_row(world).state).to eq('active')

      first.reference.update_columns(text: first.reference.text.sub("\nedited", ''))
      first.reference.discard
      expect { boost!(user, world) }.to error_code('reference_broken')
    end
  end

  describe 'consent generation' do
    def publish_pending!(&block)
      Sidekiq::Testing.fake! do
        block.call
        ExternalBridge::LinkReferencePublishWorker.drain
        ExternalBridge::LinkBoostAnnounceWorker.drain
      end
    ensure
      Sidekiq::Testing.inline!
    end

    it 'does not announce a request made before a revoke and a new grant of the same scope' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
      old = nil

      publish_pending! do
        old = boost!(user, world).wrapper
        ExternalBridge::LinkSharing::Policy.revoke!(user: user)
        grant!(user, 'public')
      end

      row = sole_row(world)
      expect(row.state).to eq('undone')
      expect(row.ended_reason).to eq('consent_withdrawn')
      expect(calls).not_to include(old.id)
      expect(gone?(old.id)).to be(true)

      fresh = boost!(user, world)
      expect(fresh.created).to be(true)
      expect(fresh.boost.policy_revision).to eq(ExternalLinkSharePolicy.find_by(user_id: user.id).revision)
      expect(calls).to include(fresh.wrapper.id)
    end

    it 'does not announce after public to unlisted to public' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
      old = nil

      publish_pending! do
        old = boost!(user, world).wrapper
        ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: 'unlisted')
        ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: 'public')
      end

      expect(sole_row(world).state).to eq('undone')
      expect(calls).not_to include(old.id)
    end

    it 'does not announce a request that spans a feature stop and restart' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
      old = nil

      publish_pending! do
        old = boost!(user, world).wrapper
        Setting.external_bridge_link_sharing = false
        Setting.external_bridge_link_sharing = true
      end

      expect(sole_row(world).ended_reason).to eq('feature_changed')
      expect(calls).not_to include(old.id)
    end

    it 'keeps a share that was already announced when consent is revoked and granted again' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      ExternalBridge::LinkSharing::Policy.revoke!(user: user)
      grant!(user, 'public')

      expect(sole_row(world).state).to eq('active')
      expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(true)
      expect(Status.find(result.reference.id).deleted_at).to be_nil
      expect(boost!(user, world).wrapper.id).to eq(result.wrapper.id)
    end

    it 'still announces an unchanged policy after a delayed Create' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
      wrapper = nil

      publish_pending! { wrapper = boost!(user, world).wrapper }

      expect(calls).to include(wrapper.id)
      expect(sole_row(world).announced_at).to be_present
    end
  end

  describe 'canonical projections only' do
    def legacy_world(user)
      allow(ExternalBridge::VisibilitySwitch).to receive(:enabled?).and_return(false)
      built = project_for(user, body: 'Legacy body')
      built[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(5)}")
      built
    end

    it 'refuses a marked legacy personal projection and leaves no note, mapping, or wrapper' do
      user = Fabricate(:user)
      canonical = prepare(user)
      legacy = legacy_world(user)
      expect(legacy[:status].reload.visibility).to eq('personal')
      expect(legacy[:marker].user_id).to eq(user.id)

      expect { boost!(user, legacy) }.to error_code('projection_not_canonical')

      expect(ExternalProjectionLinkReference.where(user_id: user.id)).to be_empty
      expect(ExternalProjectionLinkBoost.where(user_id: user.id)).to be_empty
      expect(Status.where(account_id: user.account_id, external_projection: [false, nil]).count).to eq(0)
      expect(boost!(user, canonical).created).to be(true)
    end

    it 'still lets the owner undo and read a share after the row stopped being canonical' do
      user = Fabricate(:user)
      world = prepare(user)
      boost!(user, world)
      allow(ExternalBridge::LinkSharing::Ownership).to receive(:assert_canonical!).and_raise(ExternalBridge::Error.new(:projection_not_canonical))

      expect(ExternalBridge::LinkSharing::BoostState.active?(user, world[:status])).to be(true)
      expect(unboost!(user, world).ended).to eq(1)
    end

    it 'closes a pending share instead of announcing when the projection stops being canonical' do
      user = Fabricate(:user)
      world = prepare(user)
      calls = []
      allow(ActivityPub::DistributionWorker).to receive(:perform_async) { |id| calls << id }
      wrapper = nil
      Sidekiq::Testing.fake! do
        wrapper = boost!(user, world).wrapper
        allow(ExternalBridge::LinkSharing::Ownership).to receive(:assert_canonical!).and_raise(ExternalBridge::Error.new(:projection_not_canonical))
        ExternalBridge::LinkReferencePublishWorker.drain
        ExternalBridge::LinkBoostAnnounceWorker.drain
      end
      Sidekiq::Testing.inline!

      expect(sole_row(world).ended_reason).to eq('projection_gone')
      expect(calls).not_to include(wrapper.id)
    end

    it 'keeps the other User of the same account and a missing marker out' do
      owner = Fabricate(:user)
      roommate = share_account_user(owner.account)
      world = prepare(owner)
      enable_external_bridge_link_sharing!(owner, roommate)
      grant!(roommate, 'public')

      expect { boost!(roommate, world) }.to error_code('not_owner')
      marker = ExternalStatusProjection.find(world[:marker].id)
      expect { ExternalBridge::LinkSharing::Ownership.assert_canonical!(roommate, marker) }.to error_code('not_owner')
      expect { ExternalBridge::LinkSharing::Ownership.assert_canonical!(owner, nil) }.to error_code('not_owner')
      expect { ExternalBridge::LinkSharing::Ownership.assert_canonical!(owner, marker) }.not_to raise_error
      expect(ExternalProjectionLinkBoost.count).to eq(0)
    end
  end

  describe 'projection life cycle' do
    it 'closes the share and sends the Undo when the projection is purged' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      removals = []
      allow(RemovalWorker).to receive(:perform_async) { |id| removals << id }

      ExternalBridge::ProjectionPurge.purge_status!(world[:status])

      row = sole_row(world).reload
      expect(row.state).to eq('undone')
      expect(row.ended_reason).to eq('projection_purged')
      expect(row.external_status_projection_id).to be_nil
      expect(removals).to eq([result.wrapper.id])
      expect(Status.find(result.reference.id).deleted_at).to be_nil
      expect(ExternalProjectionLinkReference.find_by(reference_status_id: result.reference.id).external_status_projection_id).to be_nil
    end

    it 'sweeps an active row whose projection is already gone' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      ExternalProjectionLinkBoost.where(id: result.boost.id).update_all(external_status_projection_id: nil)
      removals = []
      allow(RemovalWorker).to receive(:perform_async) { |id| removals << id }

      expect(ExternalBridge::LinkSharing::Retire.end_orphans!).to eq(1)

      expect(result.boost.reload.state).to eq('undone')
      expect(removals).to eq([result.wrapper.id])
    end

    it 'keeps sharing and undo working after the source is marked deleted' do
      user = Fabricate(:user)
      world = prepare(user)
      boost!(user, world)
      world[:marker].update!(source_deleted: true)

      expect(boost!(user, world).created).to be(false)
      expect(unboost!(user, world).ended).to eq(1)
    end
  end

  describe 'reblogged' do
    it 'is read per user for one status and for a page without extra queries' do
      owner = Fabricate(:user)
      roommate = share_account_user(owner.account)
      other = Fabricate(:user)
      world = prepare(owner)
      boost!(owner, world)
      normal = Array.new(19) { Fabricate(:status, visibility: :public) }
      normal.first(3).each { |status| ReblogService.new.call(owner.account, status) }
      projections = Array.new(2) { prepare(owner) }
      statuses = [world[:status], *projections.map { |item| item[:status] }, *normal]

      ExternalBridge::Viewer.with_user(owner.id) do
        relationships = StatusRelationshipsPresenter.new(statuses, owner.account_id)
        expect(relationships.reblogs_map[world[:status].id]).to be(true)
        expect(relationships.reblogs_map[projections.first[:status].id]).to be_nil
        expect(normal.first(3).all? { |status| relationships.reblogs_map[status.id] }).to be(true)
        expect(serialized(world[:status], owner)[:reblogged]).to be(true)
        expect(serialized(projections.first[:status], owner)[:reblogged]).to be(false)
      end

      ExternalBridge::Viewer.with_user(roommate.id) do
        relationships = StatusRelationshipsPresenter.new(statuses, roommate.account_id)
        expect(relationships.reblogs_map[world[:status].id]).to be_nil
        expect(normal.first(3).all? { |status| relationships.reblogs_map[status.id] }).to be(true)
      end

      ExternalBridge::Viewer.with_user(other.id) do
        expect(StatusRelationshipsPresenter.new(statuses, other.account_id).reblogs_map[world[:status].id]).to be_nil
      end

      count_queries = lambda do |list|
        count = 0
        counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' || payload[:sql].to_s.start_with?('SAVEPOINT', 'RELEASE') }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
          ExternalBridge::Viewer.with_user(owner.id) { StatusRelationshipsPresenter.new(list, owner.account_id) }
        end
        count
      end

      expect(count_queries.call(statuses.first(2))).to eq(count_queries.call(statuses))
    end

    it 'does not turn into a flag-only read for another viewer' do
      owner = Fabricate(:user)
      world = prepare(owner)
      boost!(owner, world)

      ExternalBridge::Viewer.with_user(nil) do
        expect(StatusRelationshipsPresenter.new([world[:status]], owner.account_id).reblogs_map[world[:status].id]).to be_nil
      end
    end
  end

  describe 'database integrity' do
    it 'allows one active share per user and projection' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      other_wrapper = Status.new(account: user.account, reblog: result.reference, text: '', visibility: :public)
      other_wrapper.save!(validate: false)
      attributes = result.boost.attributes.except('id').merge('generation' => 2, 'wrapper_status_id' => other_wrapper.id)

      expect do
        ActiveRecord::Base.transaction(requires_new: true) { ExternalProjectionLinkBoost.create!(attributes) }
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'rejects a row that names the wrong user, account, reference, visibility, or wrapper' do
      user = Fabricate(:user)
      roommate = share_account_user(user.account)
      world = prepare(user)
      result = boost!(user, world)
      unboost!(user, world)
      fresh = Status.new(account: user.account, reblog: result.reference, text: '', visibility: :public)
      fresh.save!(validate: false)
      base = result.boost.attributes.except('id').merge('generation' => 2, 'state' => 'active', 'wrapper_status_id' => fresh.id, 'undone_at' => nil, 'ended_reason' => nil)
      stranger_account = Fabricate(:account)
      foreign_wrapper = Status.create!(account: stranger_account, reblog: result.reference, text: '', visibility: :public)
      unlisted_wrapper = Status.create!(account: user.account, reblog: Fabricate(:status, account: user.account, visibility: :unlisted), text: '', visibility: :unlisted)

      bad = [
        base.merge('user_id' => roommate.id),
        base.merge('account_id' => stranger_account.id),
        base.merge('visibility' => 'unlisted'),
        base.merge('wrapper_status_id' => foreign_wrapper.id),
        base.merge('wrapper_status_id' => unlisted_wrapper.id),
        base.merge('wrapper_status_id' => result.reference.id),
        base.merge('reference_status_id' => world[:status].id),
        base.merge('projection_status_id' => world[:status].id + 1),
        base.merge('generation' => 0),
        base.merge('state' => 'broken'),
        base.merge('wrapper_status_id' => nil),
      ]

      bad.each_with_index do |attributes, index|
        expect do
          ActiveRecord::Base.transaction(requires_new: true) { ExternalProjectionLinkBoost.new(attributes).save!(validate: false) }
        end.to raise_error(ActiveRecord::StatementInvalid), "row #{index} was accepted"
      end
      expect(rows_for(world).count).to eq(1)
    end

    it 'keeps identifiers immutable and ended rows ended' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      row = result.boost

      expect { ActiveRecord::Base.transaction(requires_new: true) { row.update_columns(user_id: Fabricate(:user).id) } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { ActiveRecord::Base.transaction(requires_new: true) { row.update_columns(wrapper_status_id: result.reference.id) } }.to raise_error(ActiveRecord::StatementInvalid)
      expect { ActiveRecord::Base.transaction(requires_new: true) { row.update_columns(announced_at: nil) } }.to raise_error(ActiveRecord::StatementInvalid)
      unboost!(user, world)
      expect { ActiveRecord::Base.transaction(requires_new: true) { row.update_columns(state: 'active', undone_at: nil, ended_reason: nil) } }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'keeps the reference digest immutable once written' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      mapping = ExternalProjectionLinkReference.find(result.boost.link_reference_id)

      expect(mapping.reference_digest).to eq(ExternalBridge::LinkSharing::ReferenceIntegrity.digest(result.reference.text))
      expect { ActiveRecord::Base.transaction(requires_new: true) { mapping.update_columns(reference_digest: 'f' * 64) } }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'closes the row when the wrapper is hard-deleted and survives status and user cascades' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      Status.where(id: result.wrapper.id).delete_all

      expect(result.boost.reload.state).to eq('undone')
      expect(result.boost.wrapper_status_id).to be_nil

      user2 = Fabricate(:user)
      world2 = prepare(user2)
      boost!(user2, world2)
      ExternalProjectionLinkReference.where(user_id: user2.id).delete_all
      expect(ExternalProjectionLinkBoost.where(user_id: user2.id)).to be_empty
    end
  end
end

# rubocop:enable Metrics/BlockLength
