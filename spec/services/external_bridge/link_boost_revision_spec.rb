# frozen_string_literal: true

# E4-C gate: the monotonic (revision, reblogged) pair of a projection and the
# owner-only event that follows it.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

describe 'ExternalBridge link boost revision', type: :model do
  def secrets
    %w(SECRET_BODY_c0ffee SECRET_TEXT_c0ffee SECRET_CW_c0ffee SECRET_TITLE_c0ffee)
  end

  def prepare(user, visibility: 'public', url: "https://example.com/posts/#{SecureRandom.hex(5)}")
    world = external_project_for(user, body: 'SECRET_BODY_c0ffee')
    world[:source].update!(title: 'Safe Feed Title')
    world[:resource].update!(canonical_url: url, title: 'SECRET_TITLE_c0ffee')
    world[:status].update_columns(text: 'SECRET_TEXT_c0ffee', spoiler_text: 'SECRET_CW_c0ffee')
    enable_external_bridge_link_sharing!(user)
    ExternalBridge::LinkSharing::Policy.grant!(user: user, visibility: visibility)
    world.merge(url: url)
  end

  def boost!(user, world)
    ExternalBridge::LinkSharing::Boost.call(user: user, status: world[:status])
  end

  def unboost!(user, world)
    ExternalBridge::LinkSharing::Unboost.call(user: user, status: world[:status])
  end

  def state_for(user, world)
    ExternalProjectionLinkBoostState.find_by(user_id: user.id, projection_status_id: world[:status].id)
  end

  def pair(user, world)
    row = state_for(user, world)
    row ? [row.revision, row.reblogged] : [0, false]
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

  def stream_jobs
    ExternalBridge::LinkBoostStreamWorker.jobs
  end

  before do
    allow(LinkCrawlWorker).to receive(:perform_async)
    stub_request(:any, %r{\Ahttps://example\.com/}).to_return(status: 200, body: '<html><head><title>x</title></head></html>', headers: { 'Content-Type' => 'text/html' })
  end

  after do
    Setting.external_bridge_link_sharing = false
    Setting.external_bridge_link_sharing_testers = ''
    Sidekiq::Testing.inline!
  end

  describe 'revision' do
    it 'starts at 0 and moves only when the visible state flips' do
      user = Fabricate(:user)
      world = prepare(user)
      seen = [pair(user, world)]

      boost!(user, world)
      seen << pair(user, world)
      boost!(user, world)
      seen << pair(user, world)
      unboost!(user, world)
      seen << pair(user, world)
      unboost!(user, world)
      seen << pair(user, world)
      boost!(user, world)
      seen << pair(user, world)

      expect(seen).to eq([[0, false], [1, true], [1, true], [2, false], [2, false], [3, true]])
    end

    it 'keeps ordering across a scope change that starts a new mapping at generation 1' do
      user = Fabricate(:user)
      world = prepare(user)
      first = boost!(user, world)
      unboost!(user, world)
      ExternalBridge::LinkSharing::Policy.change_visibility!(user: user, visibility: 'unlisted')
      second = boost!(user, world)

      expect(first.boost.generation).to eq(1)
      expect(second.boost.generation).to eq(1)
      expect(second.boost.link_reference_id).not_to eq(first.boost.link_reference_id)
      expect(pair(user, world)).to eq([3, true])
    end

    it 'keeps ordering across a canonical URL change' do
      user = Fabricate(:user)
      world = prepare(user)
      boost!(user, world)
      unboost!(user, world)
      world[:resource].update!(canonical_url: "https://example.com/posts/#{SecureRandom.hex(5)}")
      boost!(user, world)

      expect(pair(user, world)).to eq([3, true])
    end

    it 'lets the owner undo, and advances, after consent is revoked and the flag is off' do
      user = Fabricate(:user)
      world = prepare(user)
      boost!(user, world)
      ExternalBridge::LinkSharing::Policy.revoke!(user: user)
      Setting.external_bridge_link_sharing = false
      Setting.external_bridge_link_sharing_testers = ''

      expect(pair(user, world)).to eq([1, true])
      expect(serialized(world[:status], user)[:reblogged]).to be(true)
      unboost!(user, world)
      expect(pair(user, world)).to eq([2, false])
    end

    it 'does not move when only the Announce intent or its enqueue mark is written' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! do
        result = boost!(user, world)
        ExternalBridge::LinkReferencePublishWorker.drain
        before = pair(user, world)
        ExternalBridge::LinkBoostAnnounceWorker.drain
        result.boost.reload

        expect(result.boost.announced_at).to be_present
        expect(pair(user, world)).to eq(before)
      end
    end

    it 'advances when the Announce step closes the share' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! do
        boost!(user, world)
        ExternalBridge::LinkReferencePublishWorker.drain
        ExternalBridge::LinkSharing::Policy.revoke!(user: user)
        ExternalBridge::LinkBoostAnnounceWorker.drain
      end

      expect(ExternalProjectionLinkBoost.find_by!(user_id: user.id).ended_reason).to eq('consent_withdrawn')
      expect(pair(user, world)).to eq([2, false])
    end

    it 'advances and ends the row when the wrapper is discarded by another path' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      Sidekiq::Testing.fake! { ApplicationRecord.transaction { result.wrapper.reload.discard } }

      row = ExternalProjectionLinkBoost.find_by!(user_id: user.id)
      expect(row.state).to eq('undone')
      expect(row.ended_reason).to eq('wrapper_removed')
      expect(pair(user, world)).to eq([2, false])
      expect(serialized(world[:status], user)[:reblogged]).to be(false)
      expect(stream_jobs.map { |job| job['args'] }).to eq([[user.id.to_s, world[:status].id.to_s]])
    end

    it 'advances when the wrapper row is hard-deleted' do
      user = Fabricate(:user)
      world = prepare(user)
      result = boost!(user, world)
      Status.unscoped.where(id: result.wrapper.id).delete_all

      expect(pair(user, world)).to eq([2, false])
    end

    it 'drops the pair with the projection on purge' do
      user = Fabricate(:user)
      world = prepare(user)
      boost!(user, world)
      expect(state_for(user, world)).to be_present

      ExternalBridge::ProjectionPurge.purge_status!(world[:status])

      expect(ExternalProjectionLinkBoostState.where(projection_status_id: world[:status].id)).to be_empty
      expect(ExternalBridge::LinkSharing::BoostState.snapshot(user, world[:status])).to eq(ExternalBridge::LinkSharing::BoostState::NONE)
    end

    it 'keeps another user of the same account, another account, an administrator, and nil at zero' do
      owner = Fabricate(:user)
      roommate = share_account_user(owner.account)
      stranger = Fabricate(:user)
      role = UserRole.create!(name: 'Revision admin', permissions: UserRole::FLAGS[:administrator], position: 50)
      admin = Fabricate(:user, role: role)
      world = prepare(owner)
      boost!(owner, world)
      status = world[:status]

      [roommate, stranger, admin].each do |viewer|
        expect(ExternalBridge::LinkSharing::BoostState.snapshot(viewer, status)).to eq(ExternalBridge::LinkSharing::BoostState::NONE)
        ExternalBridge::Viewer.with_user(viewer.id) do
          relationships = StatusRelationshipsPresenter.new([status], viewer.account_id)
          expect(relationships.link_boost_states).to be_empty
          expect(relationships.reblogs_map[status.id]).to be_nil
        end
      end
      expect(ExternalBridge::LinkSharing::BoostState.snapshot(nil, status)).to eq(ExternalBridge::LinkSharing::BoostState::NONE)

      ExternalBridge::Viewer.with_user(owner.id) do
        relationships = StatusRelationshipsPresenter.new([status], owner.account_id)
        expect(relationships.link_boost_states[status.id].to_a).to eq([true, 1])
      end

      # An owner pair is not readable through another user's account id.
      expect(
        ExternalBridge::LinkSharing::BoostState.snapshots(user_id: owner.id, account_id: stranger.account_id, status_ids: [status.id])
      ).to be_empty
    end
  end

  describe 'payloads' do
    it 'gives the owner reblogged and the revision from one pair, and nobody else a field' do
      owner = Fabricate(:user)
      roommate = share_account_user(owner.account)
      stranger = Fabricate(:user)
      world = prepare(owner)
      status = world[:status]

      expect(serialized(status, owner)).to include(reblogged: false)
      expect(serialized(status, owner)[:fedibird_external][:link_boost_revision]).to eq('0')

      boost!(owner, world)
      json = serialized(status, owner)
      expect(json[:reblogged]).to be(true)
      expect(json[:fedibird_external][:link_boost_revision]).to eq('1')

      unboost!(owner, world)
      json = serialized(status, owner)
      expect(json[:reblogged]).to be(false)
      expect(json[:fedibird_external][:link_boost_revision]).to eq('2')

      [roommate, stranger].each do |viewer|
        other = serialized(status, viewer)
        expect(other).not_to have_key(:fedibird_external)
        expect(other.to_json).not_to include('link_boost_revision')
      end
      anonymous = ActiveModelSerializers::SerializableResource.new(status, serializer: REST::StatusSerializer, scope: nil, scope_name: :current_user).to_json
      expect(anonymous).not_to include('link_boost_revision')
    end

    it 'reads the same pair on the page path and on the single-status path' do
      owner = Fabricate(:user)
      world = prepare(owner)
      boost!(owner, world)

      ExternalBridge::Viewer.with_user(owner.id) do
        relationships = StatusRelationshipsPresenter.new([world[:status]], owner.account_id)
        paged = JSON.parse(
          ActiveModelSerializers::SerializableResource.new(
            world[:status],
            serializer: REST::StatusSerializer,
            scope: owner,
            scope_name: :current_user,
            relationships: relationships
          ).to_json
        )
        expect(paged['reblogged']).to be(true)
        expect(paged['fedibird_external']['link_boost_revision']).to eq('1')
        expect(paged['fedibird_external']['link_boost_revision']).to eq(serialized(world[:status], owner)[:fedibird_external][:link_boost_revision])
      end
    end

    it 'ignores a caller override of reblogged for a projection so the pair cannot be mixed' do
      owner = Fabricate(:user)
      world = prepare(owner)
      boost!(owner, world)

      ExternalBridge::Viewer.with_user(owner.id) do
        relationships = StatusRelationshipsPresenter.new([world[:status]], owner.account_id, reblogs_map: { world[:status].id => false })
        json = JSON.parse(
          ActiveModelSerializers::SerializableResource.new(
            world[:status],
            serializer: REST::StatusSerializer,
            scope: owner,
            scope_name: :current_user,
            relationships: relationships
          ).to_json
        )
        expect(json['reblogged']).to be(true)
        expect(json['fedibird_external']['link_boost_revision']).to eq('1')
      end
    end

    it 'leaves a normal status without the field and keeps its Account-scoped reblogged' do
      owner = Fabricate(:user)
      roommate = share_account_user(owner.account)
      normal = Fabricate(:status, visibility: :public)
      ReblogService.new.call(owner.account, normal)

      expect(serialized(normal, owner)).not_to have_key(:fedibird_external)
      expect(serialized(normal, owner)[:reblogged]).to be(true)
      expect(serialized(normal, roommate)[:reblogged]).to be(true)
      expect(serialized(normal, Fabricate(:user))[:reblogged]).to be(false)
    end

    it 'adds one read for a page of 40 and no query of the boost rows' do
      owner = Fabricate(:user)
      worlds = Array.new(3) { prepare(owner) }
      worlds.each { |world| boost!(owner, world) }
      statuses = worlds.map { |world| world[:status] } + Array.new(37) { Fabricate(:status, visibility: :public) }

      capture = lambda do |list|
        queries = []
        counter = ->(*, payload) { queries << payload[:sql] if payload[:name] != 'SCHEMA' }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
          ExternalBridge::Viewer.with_user(owner.id) { StatusRelationshipsPresenter.new(list, owner.account_id) }
        end
        queries
      end

      small = capture.call(statuses.first(5))
      page = capture.call(statuses)
      expect(small.count { |sql| sql.include?('external_projection_link_boost_states') }).to eq(1)
      expect(page.count { |sql| sql.include?('external_projection_link_boost_states') }).to eq(1)
      expect(page.count { |sql| sql.include?('FROM external_projection_link_boosts') }).to eq(0)
    end
  end

  describe 'event' do
    it 'enqueues one owner job after the outermost commit and none for a retry or duplicate Undo' do
      user = Fabricate(:user)
      world = prepare(user)

      Sidekiq::Testing.fake! do
        boost!(user, world)
        expect(stream_jobs.map { |job| job['args'] }.uniq).to eq([[user.id.to_s, world[:status].id.to_s]])
        stream_jobs.clear

        boost!(user, world)
        expect(stream_jobs).to be_empty

        unboost!(user, world)
        expect(stream_jobs.size).to eq(1)
        stream_jobs.clear

        unboost!(user, world)
        expect(stream_jobs).to be_empty
      end
    end

    it 'enqueues nothing while the transaction is open and nothing after a rollback' do
      user = Fabricate(:user)
      world = prepare(user)

      Sidekiq::Testing.fake! do
        ApplicationRecord.transaction(requires_new: true) do
          boost!(user, world)
          expect(stream_jobs).to be_empty
          raise ActiveRecord::Rollback
        end

        expect(stream_jobs).to be_empty
        expect(ExternalProjectionLinkBoost.where(user_id: user.id)).to be_empty
        expect(pair(user, world)).to eq([0, false])
      end
    end

    it 'does not fail the boost or the Undo when Sidekiq refuses the job, and REST still carries the pair' do
      user = Fabricate(:user)
      world = prepare(user)
      allow(ExternalBridge::LinkBoostStreamWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      expect { boost!(user, world) }.not_to raise_error
      expect(serialized(world[:status], user)[:fedibird_external][:link_boost_revision]).to eq('1')
      expect { unboost!(user, world) }.not_to raise_error
      expect(serialized(world[:status], user)[:fedibird_external][:link_boost_revision]).to eq('2')
    end
  end

  describe 'worker' do
    let(:published) { [] }

    before do
      allow_any_instance_of(ExternalBridge::Streaming::Publisher).to receive(:publish) do |_publisher, channel, event, payload, delivery: nil|
        published << { channel: channel, event: event, payload: payload, delivery: delivery }
        true
      end
    end

    def run_worker(user, world)
      ExternalBridge::LinkBoostStreamWorker.new.perform(user.id.to_s, world[:status].id.to_s)
    end

    it 'publishes the current pair to the owner boost channel only, with ids and a bool' do
      user = Fabricate(:user)
      roommate = share_account_user(user.account)
      world = prepare(user)
      Sidekiq::Testing.fake! { boost!(user, world) }
      run_worker(user, world)

      expect(published.size).to eq(1)
      entry = published.first
      expect(entry[:channel]).to eq("timeline:external:user:#{user.id}:boost")
      expect(entry[:channel]).not_to include(roommate.id.to_s) unless roommate.id == user.id
      expect(entry[:event]).to eq('external_link_boost_changed')
      expect(entry[:payload]).to eq('version' => 1, 'status_id' => world[:status].id.to_s, 'reblogged' => true, 'revision' => '1')
      expect(entry[:delivery]).to eq('kind' => 'boost', 'user_id' => user.id.to_s, 'status_id' => world[:status].id.to_s, 'revision' => '1')
      secrets.each { |secret| expect(entry.to_json).not_to include(secret) }
      expect(entry.to_json).not_to include(world[:url])
    end

    it 'publishes the pair that exists when the job runs, so an old job cannot publish an old pair' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! do
        boost!(user, world)
        unboost!(user, world)
        boost!(user, world)
      end
      3.times { run_worker(user, world) }

      expect(published.map { |entry| entry[:payload]['revision'] }).to eq(%w(3 3 3))
      expect(published.map { |entry| entry[:payload]['reblogged'] }.uniq).to eq([true])
    end

    it 'publishes after the flag is off and consent is revoked' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! do
        boost!(user, world)
        ExternalBridge::LinkSharing::Policy.revoke!(user: user)
        Setting.external_bridge_link_sharing = false
        unboost!(user, world)
      end
      run_worker(user, world)

      expect(published.map { |entry| entry[:payload].slice('reblogged', 'revision') }).to eq(['reblogged' => false, 'revision' => '2'])
    end

    it 'publishes nothing for a user who is not the marker owner, an unknown pair, or a disabled user' do
      owner = Fabricate(:user)
      roommate = share_account_user(owner.account)
      world = prepare(owner)
      Sidekiq::Testing.fake! { boost!(owner, world) }

      ExternalBridge::LinkBoostStreamWorker.new.perform(roommate.id.to_s, world[:status].id.to_s)
      ExternalBridge::LinkBoostStreamWorker.new.perform(owner.id.to_s, '0')
      owner.update_columns(disabled: true)
      run_worker(owner, world)

      expect(published).to be_empty
    end

    it 'publishes nothing once the pair is purged' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! do
        boost!(user, world)
        ExternalBridge::ProjectionPurge.purge_status!(world[:status])
      end
      ExternalBridge::LinkBoostStreamWorker.new.perform(user.id.to_s, world[:status].id.to_s)

      expect(published).to be_empty
    end

    it 'raises on a Redis error so Sidekiq retries' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! { boost!(user, world) }
      allow_any_instance_of(ExternalBridge::Streaming::Publisher).to receive(:publish).and_raise(Redis::CannotConnectError)

      expect { run_worker(user, world) }.to raise_error(Redis::CannotConnectError)
    end
  end

  describe 'notification outbox' do
    let(:published) { [] }

    before do
      allow_any_instance_of(ExternalBridge::Streaming::Publisher).to receive(:publish) do |_publisher, channel, event, payload, delivery: nil|
        published << { channel: channel, event: event, payload: payload, delivery: delivery }
        true
      end
    end

    def pending_pairs
      ExternalProjectionLinkBoostState.where('revision > notified_revision').pluck(:user_id, :projection_status_id)
    end

    def recover(settle: 0.seconds)
      ExternalBridge::LinkSharing::RecoverUnnotified.call(settle: settle)
    end

    it 'covers a wrapper deleted with plain SQL, after commit, once, to the owner only' do
      user = Fabricate(:user)
      roommate = share_account_user(user.account)
      world = prepare(user)
      result = nil
      Sidekiq::Testing.fake! do
        result = boost!(user, world)
        stream_jobs.clear
        ExternalBridge::LinkBoostStreamWorker.new.perform(user.id.to_s, world[:status].id.to_s)
      end
      expect(pending_pairs).to be_empty
      published.clear

      Sidekiq::Testing.fake! do
        Status.unscoped.where(id: result.wrapper.id).delete_all

        expect(pair(user, world)).to eq([2, false])
        expect(stream_jobs).to be_empty
        expect(pending_pairs).to eq([[user.id, world[:status].id]])
        expect(recover(settle: 10.seconds)).to eq(0)
        expect(recover).to eq(1)
        expect(stream_jobs.map { |job| job['args'] }).to eq([[user.id.to_s, world[:status].id.to_s]])
        stream_jobs.each { |job| ExternalBridge::LinkBoostStreamWorker.new.perform(*job['args']) }
      end

      expect(published.map { |entry| entry[:channel] }).to eq(["timeline:external:user:#{user.id}:boost"])
      expect(published.first[:payload]).to eq('version' => 1, 'status_id' => world[:status].id.to_s, 'reblogged' => false, 'revision' => '2')
      expect(published.to_json).not_to include("timeline:external:user:#{roommate.id}:") unless roommate.id == user.id
      expect(pending_pairs).to be_empty
      expect(Sidekiq::Testing.fake! { recover }).to eq(0)
    end

    it 'announces nothing for a delete that is rolled back' do
      user = Fabricate(:user)
      world = prepare(user)
      result = nil
      Sidekiq::Testing.fake! do
        result = boost!(user, world)
        ExternalBridge::LinkBoostStreamWorker.new.perform(user.id.to_s, world[:status].id.to_s)
        stream_jobs.clear
        ApplicationRecord.transaction(requires_new: true) do
          Status.unscoped.where(id: result.wrapper.id).delete_all
          expect(pair(user, world)).to eq([2, false])
          raise ActiveRecord::Rollback
        end

        expect(pair(user, world)).to eq([1, true])
        expect(pending_pairs).to be_empty
        expect(recover).to eq(0)
        expect(stream_jobs).to be_empty
      end
    end

    it 'recovers a job Sidekiq refused, and the ordinary path acknowledges the revision it published' do
      user = Fabricate(:user)
      world = prepare(user)
      allow(ExternalBridge::LinkBoostStreamWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      boost!(user, world)
      expect(pending_pairs).to eq([[user.id, world[:status].id]])
      expect(published).to be_empty
      allow(ExternalBridge::LinkBoostStreamWorker).to receive(:perform_async).and_call_original

      expect(recover).to eq(1)
      expect(published.map { |entry| entry[:payload]['revision'] }).to eq(['1'])
      expect(pending_pairs).to be_empty
    end

    it 'keeps a flip that lands after the read pending' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! { boost!(user, world) }
      worker = ExternalBridge::LinkBoostStreamWorker.new

      allow_any_instance_of(ExternalBridge::Streaming::Publisher).to receive(:publish) do
        Sidekiq::Testing.fake! { unboost!(user, world) }
        true
      end
      worker.perform(user.id.to_s, world[:status].id.to_s)

      expect(pair(user, world)).to eq([2, false])
      expect(ExternalProjectionLinkBoostState.find_by!(user_id: user.id).notified_revision).to eq(1)
      expect(pending_pairs).to eq([[user.id, world[:status].id]])
    end

    it 'does not leave a purged projection pending, and acknowledges a user who cannot be notified' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! do
        boost!(user, world)
        ExternalBridge::ProjectionPurge.purge_status!(world[:status])
      end
      expect(pending_pairs).to be_empty

      other = Fabricate(:user)
      other_world = prepare(other)
      Sidekiq::Testing.fake! { boost!(other, other_world) }
      other.update_columns(disabled: true)
      expect(recover).to eq(1)
      Sidekiq::Testing.fake! { ExternalBridge::LinkBoostStreamWorker.new.perform(other.id.to_s, other_world[:status].id.to_s) }
      expect(pending_pairs).to be_empty
      expect(published).to be_empty
    end

    describe 'claims' do
      let(:owner) { Fabricate(:user) }
      let(:base_id) { 900_000_000_000_000_000 }

      def seed_pending(count, user: owner)
        connection = ActiveRecord::Base.connection
        connection.execute(<<~SQL.squish)
          INSERT INTO external_projection_link_boost_states
            (user_id, projection_status_id, revision, notified_revision, reblogged, created_at, updated_at)
          SELECT #{connection.quote(user.id)}, #{base_id} + series, 2, 1, FALSE,
                 NOW() - interval '1 hour' + (series % 1000) * interval '1 second',
                 NOW() - interval '1 hour' + (series % 1000) * interval '1 second'
          FROM generate_series(#{user_offset(user)}, #{user_offset(user) + count - 1}) AS series
        SQL
        Array.new(count) { |index| base_id + user_offset(user) + index }
      end

      def user_offset(user)
        user.id == owner.id ? 0 : 1_000_000
      end

      def claim_of(status_id)
        ExternalProjectionLinkBoostState.find_by!(user_id: owner.id, projection_status_id: status_id).next_notify_at
      end

      def record_pushes(accept:)
        pushed = []
        allow(ExternalBridge::LinkBoostStreamWorker).to receive(:perform_async) do |_user, status|
          pushed << status.to_i
          accept.call(status.to_i) ? 'jid' : nil
        end
        pushed
      end

      it 'reaches rows behind a head that Sidekiq keeps refusing, in a finite number of passes' do
        ids = seed_pending(230)
        head = ids.first(100)
        pushed = record_pushes(accept: ->(id) { !head.include?(id) })

        first = recover
        expect(first).to eq(100)
        expect(pushed.size).to eq(100)
        expect(pushed.sort).to eq(head)
        expect(claim_of(head.first)).to be <= Time.current

        expect(recover).to eq(100)
        second = pushed.drop(100)
        expect(second & head).to be_empty
        expect(second.size).to eq(100)

        # The 30 rows that were never tried come first, then the refused head.
        expect(recover).to eq(100)
        third = pushed.drop(200)
        expect(third.first(30).sort).to eq(ids.last(30))
        expect(third.drop(30) - head).to be_empty
        expect(pushed.first(230).uniq.size).to eq(230)

        pushed.clear
        # Accepted rows are held. Only the refused head is tried again.
        expect(recover).to eq(100)
        expect(pushed.sort).to eq(head)
      end

      it 'does not stack jobs for rows whose job was accepted, and tries them again when the hold runs out' do
        ids = seed_pending(150)
        pushed = record_pushes(accept: ->(_id) { true })

        4.times { recover }

        expect(pushed.sort).to eq(ids)
        expect(pushed.tally.values.uniq).to eq([1])

        ExternalProjectionLinkBoostState.where(user_id: owner.id).update_all("next_notify_at = NOW() - interval '1 minute'")
        expect(recover).to eq(100)
        expect(recover).to eq(50)
        expect(recover).to eq(0)
        expect(pushed.tally.values.uniq).to eq([2])
      end

      it 'treats a Redis error like a refusal and releases only its own claim' do
        ids = seed_pending(3)
        allow(ExternalBridge::LinkBoostStreamWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

        expect(recover).to eq(3)
        ids.each { |id| expect(claim_of(id)).to be <= Time.current }

        pushed = record_pushes(accept: ->(_id) { true })
        expect(recover).to eq(3)
        expect(pushed.sort).to eq(ids)
      end

      it 'notifies again a row whose revision moved after it was claimed or acknowledged' do
        user = owner
        world = prepare(user)
        allow(ExternalBridge::LinkBoostStreamWorker).to receive(:perform_async).and_return('jid')
        boost!(user, world)
        Status.unscoped.where(id: ExternalProjectionLinkBoost.find_by!(user_id: user.id).wrapper_status_id).delete_all
        expect(recover).to eq(1)
        expect(recover).to eq(0)

        state = ExternalProjectionLinkBoostState.find_by!(user_id: user.id)
        expect(state.next_notify_at).to be > Time.current
        expect(state.revision).to eq(2)

        # Another flip resets the claim, so the new revision is not held back.
        ExternalProjectionLinkBoostState.where(user_id: user.id).update_all(notified_revision: 2)
        boost!(user, world)
        state = ExternalProjectionLinkBoostState.find_by!(user_id: user.id)
        expect([state.revision, state.reblogged, state.next_notify_at]).to eq([3, true, nil])
        expect(recover).to eq(1)
        ExternalBridge::LinkBoostStreamWorker.new.perform(user.id.to_s, world[:status].id.to_s)
        expect(pending_pairs).to be_empty
      end

      it 'never moves notified_revision backwards' do
        user = owner
        world = prepare(user)
        Sidekiq::Testing.fake! { boost!(user, world) }
        ExternalBridge::LinkBoostStreamWorker.new.perform(user.id.to_s, world[:status].id.to_s)
        ExternalProjectionLinkBoostState.where(user_id: user.id).update_all(revision: 5, notified_revision: 4)

        ExternalBridge::LinkBoostStreamWorker.new.send(:acknowledge, user.id, world[:status].id, 2)

        expect(ExternalProjectionLinkBoostState.find_by!(user_id: user.id).notified_revision).to eq(4)
      end

      it 'drops a claim with an invalid user or a missing marker once the worker has run, and never selects an acknowledged row' do
        ids = seed_pending(2)
        disabled = Fabricate(:user)
        disabled.update_columns(disabled: true)
        seed_pending(1, user: disabled)
        Sidekiq::Testing.fake! do
          expect(recover).to eq(3)
          ExternalBridge::LinkBoostStreamWorker.jobs.each { |job| ExternalBridge::LinkBoostStreamWorker.new.perform(*job['args']) }
        end

        expect(pending_pairs).to be_empty
        expect(published).to be_empty
        expect(recover).to eq(0)
        expect(ids.size).to eq(2)
      end
    end

    it 'is bounded and runs from the scheduler without reading the feature flag' do
      user = Fabricate(:user)
      world = prepare(user)
      Sidekiq::Testing.fake! { boost!(user, world) }
      Setting.external_bridge_link_sharing = false
      stub_const('ExternalBridge::LinkSharing::RecoverUnnotified::SETTLE', 0.seconds)

      expect(Sidekiq::Testing.fake! { Scheduler::ExternalBridgeLinkBoostNotifyScheduler.new.perform }).to eq(1)
      expect(ExternalBridge::LinkSharing::RecoverUnnotified::BATCH).to eq(100)
    end
  end

  describe 'rollback floor' do
    it 'refuses to drop the state table while a row exists, and allows it when empty' do
      user = Fabricate(:user)
      world = prepare(user)

      expect { ActiveRecord::Base.connection.execute(ExternalBridge::Schema::LINK_BOOST_STATE_ROLLBACK_FLOOR_SQL) }.not_to raise_error

      boost!(user, world)

      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(ExternalBridge::Schema::LINK_BOOST_STATE_ROLLBACK_FLOOR_SQL)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /refusing to roll back external link boost states/)
      expect(state_for(user, world)).to be_present
    end

    it 'keeps the trigger definitions in the schema loader and in the migration' do
      sql = ExternalBridge::Schema::DEFINITIONS_SQL

      expect(sql).to include('external_projection_link_boosts_track_state')
      expect(sql).to include('statuses_end_link_boost_on_discard')
      expect(File.read(Rails.root.join('db/schema.rb'))).to include('external_projection_link_boost_states')
    end
  end

  describe 'normal statuses' do
    it 'does not enqueue a boost event when an ordinary boost is discarded' do
      account = Fabricate(:account)
      normal = Fabricate(:status, visibility: :public)
      wrapper = ReblogService.new.call(account, normal)

      Sidekiq::Testing.fake! do
        wrapper.discard
        expect(stream_jobs).to be_empty
      end
    end
  end
end

# rubocop:enable Metrics/BlockLength
