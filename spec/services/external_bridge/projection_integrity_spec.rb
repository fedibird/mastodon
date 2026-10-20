# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'digest'

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

    it 'reinstalls projection triggers from the schema definition after they are dropped' do
      connection = ActiveRecord::Base.connection
      ActiveRecord::Base.transaction(requires_new: true) do
        connection.execute(<<~SQL)
          DROP TRIGGER IF EXISTS users_external_projection_account_guard ON users;
          DROP TRIGGER IF EXISTS statuses_external_projection_field_guard ON statuses;
          DROP TRIGGER IF EXISTS external_status_projections_guard_delete ON external_status_projections;
          DROP TRIGGER IF EXISTS external_status_projections_user_account ON external_status_projections;
          ALTER TABLE external_status_projections DROP CONSTRAINT IF EXISTS fk_external_projections_subscription_owner;
          ALTER TABLE external_status_projections DROP CONSTRAINT IF EXISTS fk_external_projections_resource_source;
        SQL
        expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_status_projections_guard_delete' AND NOT tgisinternal")).to be_nil

        connection.execute(ExternalBridge::Schema::DEFINITIONS_SQL)
        expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'external_status_projections_guard_delete' AND NOT tgisinternal")).to eq 1
        expect(connection.select_value("SELECT 1 FROM pg_constraint WHERE conname = 'fk_external_projections_subscription_owner'")).to eq 1
        raise ActiveRecord::Rollback
      end
    end

    it 'keeps the trigger SQL in a schema dump' do
      stream = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, stream)
      dumped = stream.string
      schema = File.read(Rails.root.join('db/schema.rb'))
      expect(dumped).to include('execute ExternalBridge::Schema::DEFINITIONS_SQL')
      expect(schema).to include('execute ExternalBridge::Schema::DEFINITIONS_SQL')
      expect(schema).to include('INCLUDE (id)')
      expect(dumped).not_to include('INCLUDE (id)')
    end

    it 'dumps and loads the projection guards into a scratch database' do
      schema_file = Rails.root.join('db/schema.rb')
      retained = Digest::SHA256.file(schema_file).hexdigest
      dump_path = Rails.root.join('tmp/external_bridge_schema_probe.rb')
      FileUtils.rm_f(dump_path)
      probe = nil

      dump_out, dump_status = Open3.capture2e(
        { 'RAILS_ENV' => 'test', 'SCHEMA' => dump_path.to_s },
        'bundle', 'exec', 'rake', 'db:schema:dump',
        chdir: Rails.root.to_s
      )
      expect(dump_status).to be_success, dump_out
      expect(File.read(dump_path)).to include('execute ExternalBridge::Schema::DEFINITIONS_SQL')
      expect(Digest::SHA256.file(schema_file).hexdigest).to eq retained
      expect(File.read(schema_file)).to include('INCLUDE (id)')

      load_out, load_status = Open3.capture2e(
        { 'RAILS_ENV' => 'test', 'SCHEMA' => dump_path.to_s, 'DB_NAME' => 'eb_schema_probe' },
        'bundle', 'exec', 'rake', 'db:create', 'db:schema:load',
        chdir: Rails.root.to_s
      )
      expect(load_status).to be_success, load_out

      probe = scratch_database_connection('eb_schema_probe_test')
      triggers = probe.exec(<<~SQL).values.flatten.sort
        SELECT tgname FROM pg_trigger
        WHERE NOT tgisinternal AND tgname IN (
          'external_status_projections_user_account',
          'external_status_projections_guard_delete',
          'statuses_external_projection_field_guard',
          'users_external_projection_account_guard'
        )
      SQL
      expect(triggers).to eq %w(
        external_status_projections_guard_delete
        external_status_projections_user_account
        statuses_external_projection_field_guard
        users_external_projection_account_guard
      ).sort

      constraints = probe.exec(<<~SQL).values.flatten.sort
        SELECT conname FROM pg_constraint
        WHERE contype = 'f' AND conname IN (
          'fk_external_projections_subscription_owner',
          'fk_external_projections_resource_source'
        )
      SQL
      expect(constraints).to eq %w(fk_external_projections_resource_source fk_external_projections_subscription_owner)

      function_body = probe.exec("SELECT prosrc FROM pg_proc WHERE proname = 'external_status_projections_enforce_owner_account'").getvalue(0, 0)
      expect(function_body).to include('external_projection')
      expect(function_body).to include(ExternalBridge::Schema::PERSONAL_VISIBILITY.to_s)
      expect(Digest::SHA256.file(schema_file).hexdigest).to eq retained
    ensure
      probe&.close
      FileUtils.rm_f(dump_path) if dump_path
      Open3.capture2e(
        { 'RAILS_ENV' => 'test', 'DB_NAME' => 'eb_schema_probe' },
        'bundle', 'exec', 'rake', 'db:drop',
        chdir: Rails.root.to_s
      )
    end

    def scratch_database_connection(dbname)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      options = { dbname: dbname }
      host = config[:host] || config['host']
      port = config[:port] || config['port']
      username = config[:username] || config['username']
      password = config[:password] || config['password']
      options[:host] = host if host.present?
      options[:port] = port if port.present?
      options[:user] = username if username.present?
      options[:password] = password if password.present?
      PG.connect(options)
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

    it 'rejects a marker on a public status or an ordinary personal status' do
      expect(Status.visibilities[:personal]).to eq ExternalBridge::Schema::PERSONAL_VISIBILITY
      public_status = Fabricate(:status, account: user.account, visibility: :public)
      ordinary = Fabricate(:status, account: user.account, visibility: :personal, searchability: :personal)
      resource = ExternalResource.create!(
        external_source: marker.external_source,
        protocol: 'rss',
        canonical_key: "guard-#{SecureRandom.hex(4)}",
        title: 'Guard',
        body: 'Guard'
      )

      [public_status, ordinary].each do |candidate|
        expect_database_rejection(<<~SQL.squish)
          INSERT INTO external_status_projections
            (user_id, account_id, external_source_id, external_subscription_id, external_resource_id, status_id, source_deleted, created_at, updated_at)
          VALUES
            (#{user.id}, #{user.account_id}, #{marker.external_source_id}, #{marker.external_subscription_id}, #{resource.id}, #{candidate.id}, false, NOW(), NOW())
        SQL
        expect(ExternalStatusProjection.where(status_id: candidate.id)).to be_empty
      end

      expect(public_status.reload.visibility).to eq 'public'
      expect(public_status.external_projection).not_to be true
      expect(ordinary.reload.visibility).to eq 'personal'
      expect(ordinary.external_projection).not_to be true
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

    it 'drops a planted document through favourite, bookmark, stat, and a full rebuild' do
      # Release gate. Select this example by file:line or -e 'drops a planted document'.
      # -e 'raw document' is not in the name, so RSpec runs 0 examples.
      # ES_ENABLED=true is required. A skip is not a pass. Use a test-only
      # cluster and ES_PREFIX: this calls StatusesIndex.import!.
      #
      #   RAILS_ENV=test ES_ENABLED=true ES_HOST=127.0.0.1 ES_PORT=9200 \
      #     ES_PREFIX=fedibird-p1-spec bundle exec rspec \
      #     spec/services/external_bridge/projection_integrity_spec.rb:376 \
      #     --format documentation
      skip <<~MSG.squish unless elasticsearch_available?
        Elasticsearch release gate: cluster is not reachable.
        ES_ENABLED=true is required. A skip is not a pass.
        Select this example by file:line or -e "drops a planted document".
        -e "raw document" matches nothing.
      MSG

      ordinary = Fabricate(:status, account: user.account, text: 'indexed ordinary')
      Chewy.strategy(:urgent) do
        StatusesIndex.import!
        StatusesIndex.import!(status)
        expect(raw_document(status.id)).to be_nil
        expect(raw_document(ordinary.id)).to be_present

        Favourite.create!(account: user.account, status: status)
        Bookmark.create!(account: user.account, status: status)
        status.status_stat.update!(favourites_count: 1)
        StatusesIndex.import!(status)
        expect(raw_document(status.id)).to be_nil

        Favourite.where(status_id: status.id).delete_all
        Bookmark.where(status_id: status.id).delete_all
        status.status_stat.update!(favourites_count: 0)
        StatusesIndex.import!
        expect(raw_document(status.id)).to be_nil
        expect(raw_document(ordinary.id)).to be_present
      end
    end

    def index_scope
      Status.include_expired.without_reblogs.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL))
    end

    def elasticsearch_available?
      return false unless Chewy.enabled?

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

    it 'refuses a marked nonlocal status whose projection flag was cleared' do
      bundle = project_for(user)
      status = bundle[:status]
      other_user = other

      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute('ALTER TABLE statuses DISABLE TRIGGER statuses_external_projection_field_guard')
        status.update_columns(external_projection: nil, uri: 'https://example.invalid/users/a/statuses/9', local: false)
        damaged = Status.find(status.id)

        expect(damaged.local?).to be false
        expect(damaged.external_projection).not_to be true
        expect(ExternalStatusProjection.exists?(status_id: damaged.id)).to be true
        expect(ExternalBridge::ProjectionPrivacy.private_status?(damaged)).to be true
        expect(ExternalBridge::ProjectionPrivacy.hidden_from?(damaged, other_user.id)).to be true
        expect(ExternalBridge::ProjectionPrivacy.hidden_from?(damaged, user.id)).to be false
        expect(Status.include_expired.without_reblogs.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL)).where(id: damaged.id)).not_to exist
        expect { ActivityPub::NoteSerializer.new(damaged).type }.to raise_error(Status::UnreleasedActivityObject)
        expect(ActivityPub::DeliveryWorker).not_to receive(:push_bulk)
        expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)
        ActivityPub::DistributionWorker.new.perform(damaged.id)

        raise ActiveRecord::Rollback
      end

      expect(status.reload.external_projection).to be true
      expect(status.uri).to be_nil
    end

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
