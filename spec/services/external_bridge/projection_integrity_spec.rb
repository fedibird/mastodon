# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalBridge::ProjectionWriter do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }

  describe 'schema' do
    it 'adds a nullable external_projection column with no default and no index' do
      column = Status.columns_hash['external_projection']

      expect(column).to be_present
      expect(column.null).to be true
      expect(column.default).to be_nil
      indexes = ActiveRecord::Base.connection.indexes(:statuses)
      expect(indexes.none? { |index| index.columns == ['external_projection'] }).to be true
      expect(indexes.none? { |index| index.unique && index.columns == %w(id account_id) }).to be true
    end

    it 'keeps the account-match trigger as an ordinary BEFORE row trigger' do
      row = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
        SELECT tgtype, tgconstraint = 0 AS ordinary
        FROM pg_trigger
        WHERE tgname = 'external_status_projections_user_account'
          AND NOT tgisinternal
      SQL

      expect(row).to be_present
      expect(row['ordinary']).to be_in([true, 't'])
      flags = row['tgtype'].to_i
      expect(flags & 1).to eq(1)
      expect(flags & 2).to eq(2)
    end
  end

  describe 'create' do
    let(:bundle) { project_for(user, body: 'Owner only text') }
    let(:status) { bundle[:status] }

    it 'commits a personal status with a null uri and no webhook' do
      expect(TriggerWebhookWorker).not_to receive(:perform_async).with('status.created', 'Status', anything)

      created = status

      expect(created.uri).to be_nil
      expect(created.external_projection).to be true
      expect(created.visibility).to eq 'personal'
      expect(created.searchability).to eq 'personal'
      expect(created.account_id).to eq user.account_id
      expect(bundle[:marker].user_id).to eq user.id
      expect(ExternalBridge::ProjectionPrivacy.private_status?(created)).to be true
    end

    it 'rolls the status back when the marker insert fails' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: 'https://feeds.example/rollback.xml')
      resource = ExternalResource.create!(external_source: source, protocol: 'rss', canonical_key: 'item-rollback', title: 'T', body: 'B')
      subscription = ExternalSubscription.create!(user: user, external_source: source)
      allow(ExternalStatusProjection).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique.new('duplicate'))

      expect do
        described_class.new.create!(user: user, subscription: subscription, resource: resource, text: 'B')
      end.to raise_error(ActiveRecord::RecordNotUnique)

      expect(Status.where(account: user.account, text: 'B', external_projection: true)).to be_empty
      expect(ExternalStatusProjection.where(external_resource_id: resource.id)).to be_empty
    end

    it 'refuses a visibility promotion and a discard' do
      expect(status.update(visibility: :public)).to be false
      expect(status.reload.visibility).to eq 'personal'
      expect(status.uri).to be_nil
      expect(status.discard).to be false
      expect(status.reload.deleted_at).to be_nil

      expect_database_rejection("UPDATE statuses SET visibility = #{Status.visibilities[:public]} WHERE id = #{status.id}")
      expect(status.reload.visibility).to eq 'personal'
    end
  end

  describe 'marker guards' do
    let(:bundle) { project_for(user) }
    let(:marker) { bundle[:marker] }
    let(:status) { bundle[:status] }

    it 'rejects a direct marker delete while the status exists' do
      expect_database_rejection("DELETE FROM external_status_projections WHERE id = #{marker.id}")

      expect(ExternalStatusProjection.exists?(marker.id)).to be true
      expect(status.reload.external_projection).to be true
    end

    it 'rejects identifier changes on the marker, the status account, and the user account' do
      expect_database_rejection("UPDATE external_status_projections SET user_id = #{other.id} WHERE id = #{marker.id}")
      expect_database_rejection("UPDATE statuses SET account_id = #{other.account_id} WHERE id = #{status.id}")
      expect_database_rejection("UPDATE users SET account_id = #{other.account_id} WHERE id = #{user.id}")

      expect(marker.reload.user_id).to eq user.id
      expect(status.reload.account_id).to eq user.account_id
      expect(user.reload.account_id).to eq user.account_id
    end

    it 'rejects a mismatched subscription user or status account' do
      foreign = ExternalSubscription.create!(user: other, external_source: marker.external_source)
      extra = Fabricate(:status, account: user.account, visibility: :personal, searchability: :personal)
      other_resource = ExternalResource.create!(
        external_source: marker.external_source,
        protocol: 'rss',
        canonical_key: "mismatch-#{SecureRandom.hex(4)}",
        title: 'Mismatch',
        body: 'Mismatch'
      )

      expect_database_rejection(<<~SQL.squish)
        INSERT INTO external_status_projections
          (user_id, account_id, external_source_id, external_subscription_id, external_resource_id, status_id, source_deleted, created_at, updated_at)
        VALUES
          (#{user.id}, #{user.account_id}, #{marker.external_source_id}, #{foreign.id}, #{other_resource.id}, #{extra.id}, false, NOW(), NOW())
      SQL
      expect(ExternalStatusProjection.where(status_id: extra.id)).to be_empty
    end

    it 'hides a flagged status with no marker from every caller, including the owner' do
      status_id = status.id
      ApplicationRecord.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute(ExternalBridge::ProjectionPurge::SETTING_SQL)
        ExternalStatusProjection.where(id: marker.id).delete_all
        ActiveRecord::Base.connection.execute("SET LOCAL fedibird.projection_status_delete = 'off'")
      end
      damaged = Status.find(status_id)

      expect(damaged.external_projection).to be true
      expect(damaged.uri).to be_nil
      expect(ExternalBridge::ProjectionAccess.allow?(user.id, damaged)).to be false
      expect(ExternalBridge::ProjectionPrivacy.hidden_from?(damaged, user.id)).to be true
      expect(TriggerWebhookWorker).not_to receive(:perform_async)
      damaged.send(:store_uri)
      expect(damaged.reload.uri).to be_nil

      expect(ActivityPub::DeliveryWorker).not_to receive(:push_bulk)
      expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)
      ActivityPub::DistributionWorker.new.perform(damaged.id)
      RemoveStatusService.new.call(damaged)
      expect(Status.exists?(damaged.id)).to be true

      ExternalBridge::ProjectionPurge.purge_status!(damaged)
      expect(Status.unscoped.exists?(status_id)).to be false
    end
  end

  describe 'physical purge' do
    let(:bundle) { project_for(user) }

    it 'removes the status and the marker without an ActivityPub delete' do
      favourite = Favourite.create!(account: user.account, status: bundle[:status])
      bookmark = Bookmark.create!(account: user.account, status: bundle[:status])

      expect(ActivityPub::DeliveryWorker).not_to receive(:push_bulk)
      expect(RemovalWorker).not_to receive(:perform_async)
      ExternalBridge::ProjectionPurge.purge_status!(bundle[:status])

      expect(Status.unscoped.exists?(bundle[:status].id)).to be false
      expect(ExternalStatusProjection.exists?(bundle[:marker].id)).to be false
      expect(Favourite.exists?(favourite.id)).to be false
      expect(Bookmark.exists?(bookmark.id)).to be false
      expect(ExternalResource.exists?(bundle[:resource].id)).to be true
    end

    it 'keeps the status and the marker when a later statement rolls back' do
      status_id = bundle[:status].id
      marker_id = bundle[:marker].id
      user_id = user.id

      expect do
        ApplicationRecord.transaction(requires_new: true) do
          ExternalBridge::DeleteUser.call(user)
          raise 'after delete'
        end
      end.to raise_error('after delete')

      expect(Status.unscoped.exists?(status_id)).to be true
      expect(ExternalStatusProjection.exists?(marker_id)).to be true
      expect(User.exists?(user_id)).to be true
      expect(Status.find(status_id).uri).to be_nil
    end

    it 'deletes one user and leaves the other user of the same account' do
      owned = bundle
      roommate = share_account_user(user.account)
      kept = project_for(roommate, body: 'Roommate secret')

      expect(ActivityPub::DeliveryWorker).not_to receive(:push_bulk)
      expect(RemovalWorker).not_to receive(:perform_async)
      ExternalBridge::DeleteUser.call(user)

      expect(User.exists?(user.id)).to be false
      expect(Status.unscoped.exists?(owned[:status].id)).to be false
      expect(ExternalStatusProjection.exists?(owned[:marker].id)).to be false
      expect(User.exists?(roommate.id)).to be true
      expect(Status.exists?(kept[:status].id)).to be true
      expect(ExternalResource.exists?(owned[:resource].id)).to be true
    end

    it 'refuses SQL user deletion and Account#destroy while a marker remains' do
      marker_id = bundle[:marker].id
      status_id = bundle[:status].id

      expect_database_rejection("DELETE FROM users WHERE id = #{user.id}")
      expect(User.exists?(user.id)).to be true
      expect(ExternalStatusProjection.exists?(marker_id)).to be true

      expect { user.account.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
      expect(Account.exists?(user.account_id)).to be true
      expect(User.exists?(user.id)).to be true
      expect(Status.exists?(status_id)).to be true
      expect(ExternalStatusProjection.exists?(marker_id)).to be true
    end
  end

  describe 'search scope' do
    let(:bundle) { project_for(user, body: 'not indexed') }
    let(:status) { bundle[:status] }

    it 'omits the projection from StatusesIndex scope through favourite and bookmark changes' do
      expect(index_scope.where(id: status.id)).not_to exist

      Favourite.create!(account: user.account, status: status)
      Bookmark.create!(account: user.account, status: status)
      status.status_stat.update!(favourites_count: 1)
      expect(index_scope.where(id: status.id)).not_to exist

      Favourite.where(status_id: status.id).delete_all
      Bookmark.where(status_id: status.id).delete_all
      expect(index_scope.where(id: status.id)).not_to exist
    end

    it 'drops a planted document when the marker is imported' do
      skip 'Elasticsearch is not available in this environment' unless elasticsearch_available?

      StatusesIndex.import!
      StatusesIndex.import!(status)
      expect(raw_document(status.id)).to be_nil
    end

    def index_scope
      Status.include_expired.without_reblogs.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL))
    end

    def elasticsearch_available?
      Chewy.client.cluster.health
      true
    rescue StandardError
      false
    end

    def raw_document(id)
      StatusesIndex.query(ids: { values: [id] }).first
    rescue StandardError
      nil
    end
  end

  describe 'workers' do
    let(:status) { project_for(user)[:status] }

    it 'does not deliver, update, or remove a projection' do
      expect(ActivityPub::DeliveryWorker).not_to receive(:push_bulk)
      expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)
      ActivityPub::DistributionWorker.new.perform(status.id)
      ActivityPub::StatusUpdateDistributionWorker.new.perform(status.id)
      DistributionWorker.new.perform(status.id)
      RemoveStatusService.new.call(status)

      expect(status.reload.deleted_at).to be_nil
      expect(ExternalStatusProjection.exists?(status_id: status.id)).to be true
    end

    it 'does not publish the id into Redis timelines' do
      before_keys = redis.keys
      FanOutOnWriteService.new.call(status)
      PushUpdateWorker.new.perform(status.account_id, status.id, 'status', 'timeline')
      expect(redis.keys - before_keys).to be_empty
      expect(redis.zscore(FeedManager.instance.key(:home, other.account_id), status.id)).to be_nil
    end

    it 'leaves an account-only unfavourite in place' do
      Favourite.create!(account: user.account, status: status)
      UnfavouriteWorker.new.perform(user.account_id, status.id)
      expect(Favourite.where(account: user.account, status: status)).to exist
    end
  end
end
