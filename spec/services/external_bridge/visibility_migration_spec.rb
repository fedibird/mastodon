# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261021180000_permit_external_visibility_projection_transition.rb')

RSpec.describe ExternalBridge::VisibilityMigration::Runner do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'migrateowner')) }
  let(:other) { Fabricate(:user) }

  before do
    Setting.external_bridge_external_visibility = false
  end

  def run_migration(**options)
    described_class.call(options)
  end

  def apply_user(target, **options)
    Dir.mktmpdir do |dir|
      settings = {
        apply: true,
        confirm_readers_ready: true,
        user_id: target.id,
        checkpoint: File.join(dir, 'checkpoint.json'),
        limit: 50,
        batch_size: 20,
      }.merge(options)
      return run_migration(**settings)
    end
  end

  describe 'writer switch' do
    it 'stores personal while the switch is off and external when it is on' do
      legacy = project_for(user, body: 'Legacy stored body')
      expect(legacy[:status].visibility).to eq 'personal'
      expect(legacy[:status].searchability).to eq 'personal'

      Setting.external_bridge_external_visibility = true
      created = project_for(user, body: 'New external body')
      expect(created[:status].visibility).to eq 'external'
      expect(created[:status].searchability).to eq 'personal'
      expect(created[:status].external_projection).to be true
      expect(created[:status].uri).to be_nil
      expect(legacy[:status].reload.visibility).to eq 'personal'

      Setting.external_bridge_external_visibility = false
      again = project_for(user, body: 'Back to personal body')
      expect(again[:status].visibility).to eq 'personal'
      expect(created[:status].reload.visibility).to eq 'external'
    end

    it 'rolls the status back when the marker insert fails' do
      source = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml", title: 'Feed')
      resource = ExternalResource.create!(external_source: source, protocol: 'rss', canonical_key: "item-#{SecureRandom.hex(4)}", title: 'T', body: 'B')
      subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
      allow(ExternalStatusProjection).to receive(:create!).and_raise('marker failed')

      expect do
        ExternalBridge::ProjectionWriter.new.create!(user: user, subscription: subscription, resource: resource, text: 'rolled back')
      end.to raise_error('marker failed')

      expect(Status.unscoped.where(text: 'rolled back')).to be_empty
      expect(ExternalStatusProjection.where(external_subscription_id: subscription.id)).to be_empty
    end

    it 'fails closed when the switch is on and the database cannot store external' do
      Setting.external_bridge_external_visibility = true
      source = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml", title: 'Feed')
      resource = ExternalResource.create!(external_source: source, protocol: 'rss', canonical_key: "item-#{SecureRandom.hex(4)}", title: 'T', body: 'B')
      subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')

      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute('DROP FUNCTION statuses_external_visibility_shape_guard() CASCADE')
        expect do
          ExternalBridge::ProjectionWriter.new.create!(user: user, subscription: subscription, resource: resource, text: 'must not insert')
        end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'external_visibility_database_not_ready' }
        expect(Status.unscoped.where(text: 'must not insert')).to be_empty
        raise ActiveRecord::Rollback
      end
    end

    it 'does not let a disallowed user import, and leaves an ordinary personal post alone' do
      Setting.external_bridge_external_visibility = true
      ordinary = PostStatusService.new.call(user.account, text: 'Ordinary personal note', visibility: 'personal')
      expect(ordinary.visibility).to eq 'personal'
      expect(ordinary.external_projection).not_to be true

      source = ExternalSource.create!(protocol: 'rss', canonical_key: "https://feeds.example/#{SecureRandom.hex(4)}.xml", title: 'Feed')
      resource = ExternalResource.create!(external_source: source, protocol: 'rss', canonical_key: "item-#{SecureRandom.hex(4)}", title: 'T', body: 'Secret import')
      subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
      count = user.account.reload.statuses_count.to_i
      result = ExternalBridge::RSS::Materialize.new.call(subscription: subscription, resources: [resource])

      expect(result.ran).to be false
      expect(Status.unscoped.where(text: 'Secret import')).to be_empty
      expect(user.account.reload.statuses_count.to_i).to eq count
    end
  end

  describe 'database permit' do
    it 'allows only a canonical 200 to 201 change and keeps text updates' do
      legacy = project_for(user, body: 'Permit body')
      ordinary = PostStatusService.new.call(user.account, text: 'Ordinary personal note', visibility: 'personal')
      status = legacy[:status].reload
      favourite = Favourite.create!(account: user.account, status: status)
      created_at = status.created_at
      edited_at = status.edited_at

      expect_database_rejection("UPDATE statuses SET visibility = 201 WHERE id = #{status.id}")
      expect(status.reload.visibility).to eq 'personal'

      ActiveRecord::Base.connection.select_value("SELECT external_visibility_migrate_status(#{status.id})")
      status.reload
      expect(status.visibility).to eq 'external'
      expect(status.text).to eq 'Permit body'
      expect(status.created_at).to eq created_at
      expect(status.edited_at).to eq edited_at
      expect(status.account_id).to eq user.account_id
      expect(Favourite.find(favourite.id).status_id).to eq status.id
      expect(status.update!(text: 'Revised after migration')).to eq true
      expect(status.reload.visibility).to eq 'external'
      expect(ordinary.reload.visibility).to eq 'personal'

      leaked = ActiveRecord::Base.connection.select_value("SELECT current_setting('fedibird.external_visibility_migration', true)")
      expect(leaked.to_s).not_to include(status.id.to_s)
      expect_database_rejection("UPDATE statuses SET visibility = 200 WHERE id = #{status.id}")
      expect_database_rejection("SELECT external_visibility_migrate_status(#{ordinary.id})")
      expect(ordinary.reload.visibility).to eq 'personal'
      ActiveRecord::Base.connection.execute("UPDATE statuses SET visibility = 0 WHERE id = #{ordinary.id}")
      expect(ordinary.reload.visibility).to eq 'public'
    end

    it 'rejects a token for another id, another direction, a normal personal row, and a second column' do
      legacy = project_for(user, body: 'Token body')
      other_legacy = project_for(other, body: 'Other body')
      ordinary = PostStatusService.new.call(user.account, text: 'Plain personal', visibility: 'personal')
      flag_only = Status.create!(
        account: user.account,
        text: 'Flag only',
        visibility: :personal,
        searchability: :personal,
        external_projection: true,
        local: true,
        reply: false
      )

      expect_database_rejection(<<~SQL)
        PERFORM set_config('fedibird.external_visibility_migration', 'on', true);
        UPDATE statuses SET visibility = 201, updated_at = clock_timestamp() WHERE id = #{legacy[:status].id}
      SQL
      expect_database_rejection(<<~SQL)
        PERFORM set_config('fedibird.external_visibility_migration', '#{other_legacy[:status].id}:' || txid_current()::text, true);
        UPDATE statuses SET visibility = 201, updated_at = clock_timestamp() WHERE id = #{legacy[:status].id}
      SQL
      expect_database_rejection(<<~SQL)
        PERFORM set_config('fedibird.external_visibility_migration', '#{legacy[:status].id}:' || txid_current()::text, true);
        UPDATE statuses SET visibility = 201, text = 'smuggled', updated_at = clock_timestamp() WHERE id = #{legacy[:status].id}
      SQL
      expect_database_rejection(<<~SQL)
        PERFORM set_config('fedibird.external_visibility_migration', '#{ordinary.id}:' || txid_current()::text, true);
        UPDATE statuses SET visibility = 201, updated_at = clock_timestamp() WHERE id = #{ordinary.id}
      SQL
      expect_database_rejection(<<~SQL)
        PERFORM set_config('fedibird.external_visibility_migration', '#{flag_only.id}:' || txid_current()::text, true);
        UPDATE statuses SET visibility = 201, updated_at = clock_timestamp() WHERE id = #{flag_only.id}
      SQL

      expect(legacy[:status].reload.visibility).to eq 'personal'
      expect(legacy[:status].text).to eq 'Token body'
      expect(other_legacy[:status].reload.visibility).to eq 'personal'
      expect(ordinary.reload.visibility).to eq 'personal'
      expect(flag_only.reload.visibility).to eq 'personal'
    end

    it 'does not leave the permit in an outer transaction or after a failed statement' do
      legacy = project_for(user, body: 'Outer body')
      second = project_for(user, body: 'Second body')

      ApplicationRecord.transaction(requires_new: true) do
        ActiveRecord::Base.connection.select_value("SELECT external_visibility_migrate_status(#{legacy[:status].id})")
        expect_database_rejection("UPDATE statuses SET visibility = 201, updated_at = clock_timestamp() WHERE id = #{second[:status].id}")
      end

      expect(legacy[:status].reload.visibility).to eq 'external'
      expect(second[:status].reload.visibility).to eq 'personal'

      expect do
        ApplicationRecord.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(<<~SQL)
            SELECT set_config('fedibird.external_visibility_migration', '#{second[:status].id}:' || txid_current()::text, true);
          SQL
          ActiveRecord::Base.connection.execute("UPDATE statuses SET text = 'nope', visibility = 201 WHERE id = #{second[:status].id}")
        end
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect(second[:status].reload.visibility).to eq 'personal'
      expect(second[:status].text).to eq 'Second body'
      expect_database_rejection("UPDATE statuses SET visibility = 201, updated_at = clock_timestamp() WHERE id = #{second[:status].id}")
    end

    it 'restores the E1 guard on the way down without rewriting a 201 row' do
      external = external_project_for(user, body: 'Stays external')
      legacy = project_for(user, body: 'Stays legacy during down')
      migration = PermitExternalVisibilityProjectionTransition.new
      connection = ActiveRecord::Base.connection

      ActiveRecord::Base.transaction(requires_new: true) do
        migration.down
        field = connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'statuses_external_projection_field_guard'")
        expect(field).not_to include('fedibird.external_visibility_migration')
        expect(connection.select_value("SELECT 1 FROM pg_proc WHERE proname = 'external_visibility_migrate_status'")).to be_nil
        expect(external[:status].reload.visibility).to eq 'external'
        expect_database_rejection("UPDATE statuses SET visibility = 201 WHERE id = #{legacy[:status].id}")
        expect(legacy[:status].reload.visibility).to eq 'personal'
        expect(legacy[:status].update!(text: 'text still editable')).to eq true

        migration.up
        restored = connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'statuses_external_projection_field_guard'")
        expect(restored).to include('fedibird.external_visibility_migration')
        expect(connection.select_value("SELECT external_visibility_migrate_status(#{legacy[:status].id})").to_i).to eq 1
        raise ActiveRecord::Rollback
      end

      expect(external[:status].reload.visibility).to eq 'external'
      expect(legacy[:status].reload.visibility).to eq 'personal'
    end
  end

  describe 'operator run' do
    it 'dry-run writes nothing and rejects a blank filter instead of scanning everyone' do
      legacy = project_for(user, body: 'Dry body')
      stamp = legacy[:status].reload.updated_at
      path = File.join(Dir.mktmpdir, 'checkpoint.json')

      result = run_migration(user_id: user.id, checkpoint: path, limit: 10)
      expect(result.mode).to eq :dry_run
      expect(result.outcome).to eq :window_complete
      expect(result.exit_code).to eq 0
      expect(result.counts[:eligible]).to eq 1
      expect(result.counts[:converted]).to eq 0
      expect(result.to_s).to include('Nothing was written')
      expect(result.to_s).not_to include('Dry body')
      expect(legacy[:status].reload.visibility).to eq 'personal'
      expect(legacy[:status].updated_at).to eq stamp
      expect(File).not_to exist(path)

      expect { run_migration(user_id: '') }.to raise_error(ExternalBridge::VisibilityMigration::Refusal)
      expect { run_migration(user_id: '0') }.to raise_error(ExternalBridge::VisibilityMigration::Refusal)
      expect { run_migration(subscription_id: 'nope') }.to raise_error(ExternalBridge::VisibilityMigration::Refusal)
      expect(legacy[:status].reload.visibility).to eq 'personal'
    end

    it 'refuses apply until the switch, the readers flag, and a checkpoint are present' do
      project_for(user)
      expect { run_migration(apply: true, user_id: user.id) }.to raise_error(ExternalBridge::VisibilityMigration::Refusal)
      Setting.external_bridge_external_visibility = true
      expect do
        run_migration(apply: true, user_id: user.id, checkpoint: File.join(Dir.mktmpdir, 'c.json'))
      end.to raise_error(ExternalBridge::VisibilityMigration::Refusal, /confirm-readers-ready/)
    end

    it 'converts only that user, keeps ids, and leaves the personal timeline' do
      legacy = project_for(user, body: 'Owned body')
      kept = project_for(other, body: 'Other owner')
      ordinary = PostStatusService.new.call(user.account, text: 'Ordinary personal note', visibility: 'personal')
      flag_only = Status.create!(account: user.account, text: 'Flag only', visibility: :personal, searchability: :personal, external_projection: true, local: true, reply: false)
      favourite = Favourite.create!(account: user.account, status: legacy[:status])
      bookmark = Bookmark.create!(account: user.account, status: legacy[:status])
      count = user.account.reload.statuses_count.to_i
      Setting.external_bridge_external_visibility = true
      before_keys = redis.keys
      expect(TriggerWebhookWorker).not_to receive(:perform_async)
      expect(DistributionWorker).not_to receive(:perform_async)
      expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)

      result = apply_user(user)
      legacy[:status].reload

      expect(result.outcome).to eq :window_complete
      expect(result.counts[:converted]).to eq 1
      expect(result.to_s).to include('not instance completion')
      expect(legacy[:status].id).to eq favourite.status_id
      expect(legacy[:status].visibility).to eq 'external'
      expect(legacy[:status].text).to eq 'Owned body'
      expect(legacy[:status].edited_at).to be_nil
      expect(Favourite.find(favourite.id).status_id).to eq legacy[:status].id
      expect(Bookmark.find(bookmark.id).status_id).to eq legacy[:status].id
      expect(kept[:status].reload.visibility).to eq 'personal'
      expect(ordinary.reload.visibility).to eq 'personal'
      expect(flag_only.reload.visibility).to eq 'personal'
      expect(user.account.reload.statuses_count.to_i).to eq count
      expect(StatusEdit.where(status_id: legacy[:status].id)).to be_empty
      expect(redis.keys - before_keys).to eq []

      owner_ids = PersonalFeed.new(user.account, viewer_user_id: user.id).get(20).map(&:id)
      expect(owner_ids).to include(ordinary.id)
      expect(owner_ids).not_to include(legacy[:status].id)

      Rails.cache.write("statuses/#{legacy[:status].id}", 'stale-personal')
      again = apply_user(user)
      expect(again.counts[:converted]).to eq 0
      expect(again.counts[:already_external]).to eq 1
      expect(Rails.cache.read("statuses/#{legacy[:status].id}")).to be_nil
    end

    it 'resumes a pending batch after a crash between commit and cache' do
      first = project_for(user, body: 'First body')
      second = project_for(user, body: 'Second body')
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      Setting.external_bridge_external_visibility = true
      Rails.cache.write("statuses/#{first[:status].id}", 'stale')
      Rails.cache.write("statuses/#{second[:status].id}", 'stale')
      crashes = 0
      injector = lambda do |name|
        next unless name == :during_cache

        crashes += 1
        raise 'partial cache' if crashes > 1
      end

      expect do
        run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 10, batch_size: 10, injector: injector)
      end.to raise_error(described_class::CacheIncomplete)

      expect(first[:status].reload.visibility).to eq 'external'
      expect(second[:status].reload.visibility).to eq 'external'
      checkpoint = JSON.parse(File.read(path))
      expect(checkpoint['pending_batch']).to be_present
      expect(checkpoint['last_completed_marker_id']).to eq 0
      expect(File.read(path)).not_to include('First body')
      expect(File.stat(path).mode & 0o777).to eq 0o600

      result = run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 10, batch_size: 10)
      expect(result.outcome).to eq :window_complete
      expect(result.counts[:converted]).to eq 0
      expect(result.counts[:already_external]).to eq 2
      expect(Rails.cache.read("statuses/#{first[:status].id}")).to be_nil
      expect(Rails.cache.read("statuses/#{second[:status].id}")).to be_nil
      expect(JSON.parse(File.read(path))['pending_batch']).to be_nil

      expect do
        run_migration(apply: true, confirm_readers_ready: true, user_id: other.id, checkpoint: path, limit: 10)
      end.to raise_error(ExternalBridge::VisibilityMigration::Refusal) { |error| expect(error.code).to eq :checkpoint_scope }
      expect(first[:status].reload.visibility).to eq 'external'
    end

    it 'does not advance the cursor past an invalid row or a lock failure' do
      broken = project_for(user, body: 'Broken shape')
      healthy = project_for(user, body: 'Healthy shape')
      ActiveRecord::Base.connection.execute("UPDATE statuses SET local = FALSE WHERE id = #{broken[:status].id}")
      Setting.external_bridge_external_visibility = true

      result = apply_user(user, batch_size: 10)
      expect(result.outcome).to eq :invalid
      expect(result.exit_code).to eq 4
      expect(result.invalid_rows.first[:reason]).to eq :shape_invalid
      expect(broken[:status].reload.visibility).to eq 'personal'
      expect(healthy[:status].reload.visibility).to eq 'personal'
      expect(result.to_s).not_to include('Broken shape')
    end

    it 'stops at the limit and continues from the checkpoint' do
      project_for(user, body: 'One')
      project_for(user, body: 'Two')
      Setting.external_bridge_external_visibility = true
      path = File.join(Dir.mktmpdir, 'checkpoint.json')

      first = run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 1, batch_size: 1)
      expect(first.outcome).to eq :limit_reached
      expect(first.exit_code).to eq 2
      expect(first.counts[:converted]).to eq 1
      expect(first.counts[:remaining_in_window]).to eq 1

      second = run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 10, batch_size: 10)
      expect(second.counts[:converted]).to eq 1
      expect(second.outcome).to eq :window_complete
      stored = Status.unscoped.where(id: ExternalStatusProjection.where(user_id: user.id).select(:status_id))
      expect(stored.map { |row| row.visibility_before_type_cast }.uniq).to eq [201]
    end

    it 'verify reports remaining legacy and a clean scope without calling the window complete' do
      legacy = project_for(user, body: 'Still legacy')
      report = run_migration(verify: true, user_id: user.id, limit: 20)
      expect(report.outcome).to eq :verify_remaining
      expect(report.exit_code).to eq 5
      expect(report.counts[:legacy_remaining]).to eq 1
      expect(legacy[:status].reload.visibility).to eq 'personal'

      Setting.external_bridge_external_visibility = true
      apply_user(user)
      clean = run_migration(verify: true, user_id: user.id, limit: 20)
      expect(clean.outcome).to eq :scope_complete
      expect(clean.to_s).to include('not instance completion')
      expect(clean.to_s).not_to include('instance_complete')
    end

    it 'refuses a subscription that belongs to someone else and still migrates a paused one' do
      legacy = project_for(user, body: 'Paused body')
      legacy[:subscription].update!(state: 'paused')
      expect do
        run_migration(user_id: other.id, subscription_id: legacy[:subscription].id)
      end.to raise_error(ExternalBridge::VisibilityMigration::Refusal, /does not belong/)

      Setting.external_bridge_external_visibility = true
      result = apply_user(user, subscription_id: legacy[:subscription].id)
      expect(result.counts[:converted]).to eq 1
      expect(legacy[:subscription].reload.state).to eq 'paused'
      expect(legacy[:status].reload.visibility).to eq 'external'

      legacy[:resource].update!(title: 'Updated title', body: 'Updated paused body', revision: 'rev-2')
      materialized = ExternalBridge::RSS::Materialize.new.call(subscription: legacy[:subscription], resources: [legacy[:resource]])
      expect(materialized.ran).to be false
      expect(legacy[:status].reload.visibility).to eq 'external'
    end

    it 'keeps a legacy row personal across an RSS revision until the operator migrates it' do
      enable_external_bridge_rss!(user)
      legacy = project_for(user, body: 'Revision body')
      Setting.external_bridge_external_visibility = true
      legacy[:resource].update!(title: 'Changed title', revision: 'rev-9')
      ExternalBridge::RSS::Materialize.new.call(subscription: legacy[:subscription], resources: [legacy[:resource]])
      expect(legacy[:status].reload.visibility).to eq 'personal'
      expect(legacy[:status].text).to include('Changed title')

      apply_user(user)
      expect(legacy[:status].reload.visibility).to eq 'external'
      legacy[:resource].update!(title: 'After migration', revision: 'rev-10')
      ExternalBridge::RSS::Materialize.new.call(subscription: legacy[:subscription], resources: [legacy[:resource]])
      expect(legacy[:status].reload.visibility).to eq 'external'
      expect(legacy[:status].text).to include('After migration')
    end
  end

  describe 'plans' do
    it 'explains a marker keyset and records the personal timeline query count for this database' do
      project_for(user)
      3.times { Fabricate(:status, account: user.account, visibility: :personal, text: 'Ordinary personal') }
      connection = ActiveRecord::Base.connection
      sql = ExternalBridge::VisibilityMigration::Scanner.relation(after: 0, watermark: 2**62, user_id: user.id, subscription_id: nil, limit: 20).to_sql
      expect(sql).to include('external_status_projections')
      expect(sql).not_to include('statuses')

      plan = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        connection.execute('SET LOCAL enable_seqscan = off')
        plan = connection.select_values("EXPLAIN #{sql}").join("\n")
        raise ActiveRecord::Rollback
      end
      expect(plan).to include('external_status_projections')
      expect(plan).not_to include('Seq Scan on statuses')

      queries = []
      callback = lambda do |*, payload|
        queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:sql].include?('SCHEMA')
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        PersonalFeed.new(user.account, viewer_user_id: user.id).get(20)
      end

      target = '/opt/cursor/artifacts/external-visibility-migration-explain.txt'
      File.write(target, "#{sql}\n\n#{plan}\n\npersonal_feed_queries=#{queries.size}\n") if File.directory?('/opt/cursor/artifacts')
      expect(queries.size).to be < 30
    end
  end

  describe 'committed connection' do
    # Another connection can see a lock only after commit. The example
    # transaction would hide the row and turn BEGIN into a savepoint.
    self.use_transactional_tests = false

    after do
      Setting.external_bridge_external_visibility = false
    end

    it 'clears the permit on the same connection after the function returns and after commit' do
      owner = Fabricate(:user)
      legacy = project_for(owner, body: 'Commit body')
      second = project_for(owner, body: 'Second commit body')
      connection = ActiveRecord::Base.connection

      connection.transaction do
        connection.select_value("SELECT external_visibility_migrate_status(#{legacy[:status].id})")
        leaked = connection.select_value("SELECT current_setting('fedibird.external_visibility_migration', true)")
        expect(leaked.to_s).not_to include(legacy[:status].id.to_s)
      end

      leaked = connection.select_value("SELECT current_setting('fedibird.external_visibility_migration', true)")
      expect(leaked.to_s).not_to include(legacy[:status].id.to_s)
      expect(legacy[:status].reload.visibility).to eq 'external'
      expect_database_rejection("UPDATE statuses SET visibility = 201, updated_at = clock_timestamp() WHERE id = #{second[:status].id}")
      expect(second[:status].reload.visibility).to eq 'personal'
    ensure
      forget_projection_owner(owner)
    end

    it 'does not advance the checkpoint past a marker another connection holds' do
      owner = Fabricate(:user)
      legacy = project_for(owner, body: 'Locked body')
      Setting.external_bridge_external_visibility = true
      dir = Dir.mktmpdir
      path = File.join(dir, 'checkpoint.json')
      ready = Queue.new
      release = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute('BEGIN')
          connection.select_value("SELECT id FROM external_status_projections WHERE id = #{legacy[:marker].id.to_i} FOR UPDATE")
          ready << :locked
          release.pop
        ensure
          connection.execute('ROLLBACK')
        end
      rescue StandardError => e
        ready << e
      end

      signal = Timeout.timeout(5) { ready.pop }
      raise signal if signal.is_a?(Exception)

      result = run_migration(
        apply: true,
        confirm_readers_ready: true,
        user_id: owner.id,
        checkpoint: path,
        limit: 10,
        batch_size: 10,
        lock_timeout: '200ms',
        statement_timeout: '2s'
      )
      expect(result.outcome).to eq :lock_conflict
      expect(result.exit_code).to eq 4
      expect(legacy[:status].reload.visibility).to eq 'personal'
      checkpoint = JSON.parse(File.read(path))
      expect(checkpoint['last_completed_marker_id']).to eq 0
      expect(checkpoint['pending_batch']['marker_ids']).to include(legacy[:marker].id)

      release << :go
      holder.join
      holder = nil

      resumed = run_migration(
        apply: true,
        confirm_readers_ready: true,
        user_id: owner.id,
        checkpoint: path,
        limit: 10,
        batch_size: 10,
        lock_timeout: '2s',
        statement_timeout: '5s'
      )
      expect(resumed.outcome).to eq :window_complete
      expect(resumed.counts[:converted]).to eq 1
      expect(legacy[:status].reload.visibility).to eq 'external'
      expect(legacy[:status].text).to eq 'Locked body'
    ensure
      if holder&.alive?
        release << :go
        holder.join
      end
      FileUtils.remove_entry(dir) if dir
      forget_projection_owner(owner)
    end
  end

  def forget_projection_owner(owner)
    return if owner.nil? || !owner.persisted?

    account = owner.account
    ExternalBridge::ProjectionPurge.purge_user!(owner)
    ExternalProjectionSuppression.where(user_id: owner.id).delete_all
    ExternalProjectionFailure.where(user_id: owner.id).delete_all
    source_ids = ExternalSubscription.where(user_id: owner.id).pluck(:external_source_id)
    ExternalSubscription.where(user_id: owner.id).delete_all
    ExternalResource.where(external_source_id: source_ids).delete_all
    ExternalSource.where(id: source_ids).delete_all
    Status.unscoped.where(account_id: account.id).delete_all if account
    owner.delete
    account&.delete
  end
end
