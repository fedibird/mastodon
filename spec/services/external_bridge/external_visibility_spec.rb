# frozen_string_literal: true

# The examples share one visibility matrix. Splitting them would hide the combinations.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'
require Rails.root.join('db/migrate/20261021140000_accept_external_visibility_projection_guards.rb')

RSpec.describe 'External visibility read and protection' do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'externalowner')) }
  let(:roommate) { share_account_user(user.account) }
  let(:stranger) { Fabricate(:user) }

  describe 'enum and write surfaces' do
    it 'keeps external internal and leaves searchability unchanged' do
      expect(Status.visibilities[:external]).to eq 201
      expect(Status.visibilities[:personal]).to eq 200
      expect(Status.searchabilities.keys).not_to include('external')
      expect(Status.composable_visibility_keys).not_to include('external')
      expect(Status.selectable_visibilities).not_to include('external')
      expect(Status::UNCOUNT_VISIBILITY).to include('external')
      expect(Status::STANDARD_VISIBILITY).not_to include('external') if Status.const_defined?(:STANDARD_VISIBILITY)

      record = UserPostingContext.new(user: user)
      UserPostingContext::Defaults.send(:validate_visibility, record, { 'visibility' => 'external' })
      expect(record.errors).to be_added(:base, I18n.t('user_posting_contexts.errors.visibility'))

      bookmark = TimelineReadingBookmarks::Context.new('public', {})
      expect { bookmark.send(:visibilities!, ['external']) }.to raise_error(TimelineReadingBookmarks::Reject)
      expect(bookmark.send(:visibilities!, ['personal'])).to eq ['personal']

      resolver = TimelineSeek::Resolver.new(user.account, user: user)
      resolver.instance_variable_set(:@context, { visibilities: ['external'] })
      expect(resolver.send(:visibility_list)).not_to eq ['external']
    end

    it 'rejects external on a normal post, a reblog option, and a scheduled post' do
      expect do
        PostStatusService.new.call(user.account, text: 'no external', visibility: 'external')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        PostStatusService.new.call(user.account, text: 'no numeric', visibility: '201')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        PostStatusService.new.call(user.account, text: 'no extension', visibility_ex: 'External')
      end.to raise_error(Mastodon::ValidationError)
      expect do
        PostStatusService.new.call(user.account, text: 'later', visibility: 'external', scheduled_at: 1.hour.from_now.iso8601)
      end.to raise_error(Mastodon::ValidationError)

      expect(Status.where(account: user.account, text: ['no external', 'no numeric', 'no extension', 'later'])).to be_empty
      expect(user.account.scheduled_statuses).to be_empty

      public_status = Fabricate(:status, account: user.account, visibility: :public, text: 'boost me')
      expect do
        ReblogService.new.call(user.account, public_status, visibility: 'external')
      end.to raise_error(Mastodon::ValidationError)
      expect(Status.where(reblog_of_id: public_status.id)).to be_empty
    end
  end

  describe 'triple-or privacy' do
    it 'treats an unsaved external value or flag as private for every caller' do
      external_only = Status.new(visibility: :external, external_projection: false, text: 'value only')
      external_only.id = 9_100_000_000_000_001
      flagged = Status.new(visibility: :public, external_projection: true, text: 'flag only')
      flagged.id = 9_100_000_000_000_002

      [external_only, flagged].each do |row|
        expect(ExternalBridge::ProjectionPrivacy.private_status?(row)).to be true
        expect(ExternalBridge::ProjectionAccess.allow?(user.id, row)).to be false
        expect(ExternalBridge::ProjectionPrivacy.hidden_from?(row, user.id)).to be true
      end

      decision = ExternalBridge::ProjectionAccess::Decision.for([external_only, flagged], user.id)
      expect(decision.private?(external_only)).to be true
      expect(decision.private?(flagged)).to be true
      expect(decision.visible?(external_only)).to be false
      expect(decision.visible?(flagged)).to be false
    end

    it 'lets only the marker user read a canonical external status' do
      bundle = external_project_for(user, body: 'Canonical external body')
      status = bundle[:status]

      expect(status.visibility).to eq 'external'
      expect(status.searchability).to eq 'personal'
      expect(status.external_projection).to be true
      expect(status.uri).to be_nil
      expect(status.local).to be true
      expect(status.search_indexable?).to be false
      expect(status.uncount_visibility?).to be true
      expect(status.compute_searchability).to eq 'personal'

      expect(ExternalBridge::ProjectionAccess.allow?(user.id, status)).to be true
      expect(ExternalBridge::ProjectionAccess.allow?(roommate.id, status)).to be false
      expect(ExternalBridge::ProjectionAccess.allow?(nil, status)).to be false
      expect(ExternalBridge::ProjectionPrivacy.hidden_from?(status, roommate.id)).to be true

      ExternalBridge::Viewer.user_id = nil
      expect(StatusPolicy.new(user.account, status).show?).to be false
      ExternalBridge::Viewer.user_id = user.id
      expect(StatusPolicy.new(user.account, status).show?).to be true
      expect(StatusPolicy.new(user.account, status).reblog?).to be false
      expect(StatusPolicy.new(user.account, status).update?).to be false
      ExternalBridge::Viewer.user_id = roommate.id
      expect(StatusPolicy.new(roommate.account, status).show?).to be false
    end

    it 'denies the owner when the marker is gone and still hides a marker whose flag was cleared' do
      missing = external_project_for(user, body: 'marker missing')
      ActiveRecord::Base.transaction(requires_new: true) do
        connection = ActiveRecord::Base.connection
        connection.execute('ALTER TABLE statuses DISABLE TRIGGER statuses_external_projection_field_guard')
        connection.execute(ExternalBridge::ProjectionPurge::SETTING_SQL)
        ExternalStatusProjection.where(id: missing[:marker].id).delete_all
        connection.execute("SET LOCAL fedibird.projection_status_delete = 'off'")
        missing[:status].update_columns(external_projection: nil)
        damaged = Status.find(missing[:status].id)

        expect(damaged.external_visibility?).to be true
        expect(damaged.external_projection).not_to be true
        expect(ExternalStatusProjection.exists?(status_id: damaged.id)).to be false
        expect(ExternalBridge::ProjectionPrivacy.private_status?(damaged)).to be true
        expect(ExternalBridge::ProjectionAccess.allow?(user.id, damaged)).to be false
        expect(ExternalBridge::ProjectionPrivacy.hidden_from?(damaged, user.id)).to be true
        raise ActiveRecord::Rollback
      end

      marked = project_for(user, body: 'flag cleared')
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute('ALTER TABLE statuses DISABLE TRIGGER statuses_external_projection_field_guard')
        marked[:status].update_columns(external_projection: nil, visibility: Status.visibilities[:public])
        damaged = Status.find(marked[:status].id)

        expect(damaged.external_projection).not_to be true
        expect(damaged.visibility).to eq 'public'
        expect(ExternalBridge::ProjectionPrivacy.private_status?(damaged)).to be true
        expect(ExternalBridge::ProjectionAccess.allow?(user.id, damaged)).to be true
        expect(ExternalBridge::ProjectionAccess.allow?(roommate.id, damaged)).to be false
        expect(ExternalBridge::ProjectionPrivacy.visible_status_relation(user.id).where(id: damaged.id)).to exist
        expect(ExternalBridge::ProjectionPrivacy.visible_status_relation(roommate.id).where(id: damaged.id)).not_to exist
        raise ActiveRecord::Rollback
      end
    end
  end

  describe 'distribution and secondary readers' do
    let(:bundle) { external_project_for(user, body: 'Do not deliver this body') }
    let(:status) { bundle[:status] }

    it 'does not mint a uri, a webhook, a redis payload, or an ActivityPub object' do
      created = status
      stranger
      expect(created.send(:external_projection_side_effect?)).to be true
      expect(TriggerWebhookWorker).not_to receive(:perform_async).with('status.created', 'Status', created.id)
      expect(TriggerWebhookWorker).not_to receive(:perform_async).with('status.updated', 'Status', created.id)
      created.send(:trigger_create_webhooks)
      created.send(:trigger_update_webhooks)
      created.send(:store_uri)
      expect(created.reload.uri).to be_nil
      expect(ActivityPub::TagManager.instance.uri_for(created)).to be_nil
      expect(ActivityPub::TagManager.instance.url_for(created)).to be_nil
      expect { ActivityPub::NoteSerializer.new(created).type }.to raise_error(Status::UnreleasedActivityObject)

      expect(ActivityPub::DeliveryWorker).not_to receive(:push_bulk)
      expect(ActivityPub::DeliveryWorker).not_to receive(:perform_async)
      ActivityPub::DistributionWorker.new.perform(created.id)
      ActivityPub::StatusUpdateDistributionWorker.new.perform(created.id)
      DistributionWorker.new.perform(created.id)
      RemoveStatusService.new.call(created)
      expect(created.reload.deleted_at).to be_nil

      before_keys = redis.keys
      FanOutOnWriteService.new.call(created)
      PushUpdateWorker.new.perform(created.account_id, created.id, 'status', 'timeline')
      expect(redis.keys - before_keys).to be_empty

      redis.zadd(FeedManager.instance.key(:home, stranger.account_id), created.id, created.id)
      hydrated = Feed.new(:home, stranger.account_id).get(20)
      expect(hydrated.map(&:id)).not_to include(created.id)

      expect { FetchLinkCardService.new.call(created) }.not_to(change { created.preview_cards.count })
    end

    it 'stays out of the personal timeline, account counts, and the search scope' do
      ordinary = PostStatusService.new.call(user.account, text: 'Ordinary personal note', visibility: 'personal')
      legacy = project_for(user, body: 'Legacy personal projection')
      before = user.account.reload.statuses_count.to_i
      created = status
      expect(user.account.reload.statuses_count.to_i).to eq before

      owner_ids = PersonalFeed.new(user.account, viewer_user_id: user.id).get(40).map(&:id)
      expect(owner_ids).to include(ordinary.id, legacy[:status].id)
      expect(owner_ids).not_to include(created.id)

      scope = Status.include_expired.without_reblogs.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL))
      expect(scope.where(id: created.id)).not_to exist
      expect(scope.where(id: legacy[:status].id)).not_to exist
      expect(scope.where(id: ordinary.id)).to exist

      backup_ids = user.account.statuses.without_unreleased_pages.where(Arel.sql(ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL)).pluck(:id)
      expect(backup_ids).not_to include(created.id)
    end
  end

  describe 'database guards' do
    it 'shares the personal and external predicates between schema load and the migration' do
      definitions = ExternalBridge::Schema::DEFINITIONS_SQL
      refresh = ExternalBridge::Schema::GUARD_REFRESH_SQL
      expect(definitions).to include('NOT IN (200, 201)')
      expect(refresh).to include('NOT IN (200, 201)')
      expect(definitions).to include('OLD.visibility = 201')
      expect(refresh).to include('OLD.visibility = 201')
      expect(definitions).to include('fedibird.external_visibility_migration')
      expect(definitions).not_to include('SET fedibird.external_visibility_migration')
      expect(ExternalBridge::Schema::MIGRATE_FUNCTION_SQL).to include('query_canceled')
      expect(ExternalBridge::Schema::MIGRATE_FUNCTION_SQL).to include("set_config('fedibird.external_visibility_migration', previous, true)")
      expect(refresh).not_to include('fedibird.external_visibility_migration')
      expect(ExternalBridge::Schema::FIELD_GUARD_FUNCTION_SQL).to include('to_jsonb(OLD)')
      expect(File.read(Rails.root.join('db/migrate/20261021180000_permit_external_visibility_projection_transition.rb'))).not_to include('DEFINITIONS_SQL')
      expect(definitions).to include('statuses_external_visibility_shape_guard')
      expect(refresh).to include('statuses_external_visibility_shape_guard')
      expect(definitions).to include('BEFORE INSERT OR UPDATE OF local, reply')
      expect(definitions).to include('quote_id, local, reply')
      expect(refresh).to include('NEW.local IS DISTINCT FROM OLD.local')
      expect(ExternalBridge::Schema::FIELD_GUARD_TRIGGER_SQL).to include('quote_id, local, reply')
      expect(ExternalBridge::Schema::SHAPE_TRIGGER_ATTACH_SQL).to include('BEFORE INSERT OR UPDATE OF local, reply')
      expect(AcceptExternalVisibilityProjectionGuards::DOWN_GUARD_SQL).to include('IS DISTINCT FROM 200')
      expect(AcceptExternalVisibilityProjectionGuards::DOWN_GUARD_SQL).not_to include('NOT IN (200, 201)')
      expect(AcceptExternalVisibilityProjectionGuards::DOWN_GUARD_SQL).not_to include('local, reply')
      expect(File.read(Rails.root.join('db/migrate/20261021140000_accept_external_visibility_projection_guards.rb'))).not_to include('DEFINITIONS_SQL')
    end

    it 'rejects a bad external shape, a marker on an ordinary status, and a visibility change' do
      ordinary = Fabricate(:status, account: user.account, visibility: :personal, searchability: :personal, text: 'ordinary personal')
      public_status = Fabricate(:status, account: user.account, visibility: :public, text: 'ordinary public')
      invalid = Status.new(account: user.account, text: 'bad shape', visibility: :external, searchability: :public, external_projection: false, local: false, uri: 'https://example.invalid/bad')
      expect(invalid).not_to be_valid

      account_id = user.account_id
      bad_id = (Time.now.to_i << 16) + 70
      expect_database_rejection(<<~SQL.squish)
        INSERT INTO statuses (id, account_id, text, visibility, searchability, uri, external_projection, local, reply, created_at, updated_at)
        VALUES (#{bad_id}, #{account_id}, 'bad raw', 201, 0, NULL, false, true, false, NOW(), NOW())
      SQL
      expect(Status.where(id: bad_id)).not_to exist

      bundle = external_project_for(user)
      expect_database_rejection("UPDATE statuses SET visibility = 0 WHERE id = #{bundle[:status].id}")
      expect_database_rejection("UPDATE statuses SET visibility = 200 WHERE id = #{bundle[:status].id}")
      expect(bundle[:status].reload.visibility).to eq 'external'
      expect_database_rejection("UPDATE statuses SET visibility = 201 WHERE id = #{ordinary.id}")
      expect(ordinary.reload.visibility).to eq 'personal'
      expect_database_rejection("DELETE FROM external_status_projections WHERE id = #{bundle[:marker].id}")
      expect(ExternalStatusProjection.exists?(bundle[:marker].id)).to be true

      resource = ExternalResource.create!(
        external_source: bundle[:source],
        protocol: 'rss',
        canonical_key: "shape-#{SecureRandom.hex(4)}",
        title: 'Shape',
        body: 'Shape'
      )
      [ordinary, public_status].each do |candidate|
        expect_database_rejection(<<~SQL.squish)
          INSERT INTO external_status_projections
            (user_id, account_id, external_source_id, external_subscription_id, external_resource_id, status_id, source_deleted, created_at, updated_at)
          VALUES
            (#{user.id}, #{user.account_id}, #{bundle[:source].id}, #{bundle[:subscription].id}, #{resource.id}, #{candidate.id}, false, NOW(), NOW())
        SQL
        expect(ExternalStatusProjection.where(status_id: candidate.id)).to be_empty
      end
    end

    it 'rejects local and reply changes on an external status without disabling triggers' do
      bundle = external_project_for(user, body: 'External shape body')
      status = bundle[:status]
      expect(status.local).to be true
      expect(status.reply).to be false

      expect_database_rejection("UPDATE statuses SET local = FALSE WHERE id = #{status.id}")
      expect(status.reload.local).to be true
      expect_database_rejection("UPDATE statuses SET reply = TRUE WHERE id = #{status.id}")
      expect(status.reload.reply).to be false

      expect { status.update!(local: false) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(status.reload.local).to be true
      expect { status.update!(reply: true) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(status.reload.reply).to be false
      expect(status.update!(text: 'Revised external body')).to eq true
      expect(status.reload.text).to eq 'Revised external body'

      ordinary = Fabricate(:status, account: user.account, visibility: :personal, text: 'ordinary personal')
      public_status = Fabricate(:status, account: user.account, visibility: :public, text: 'ordinary public')
      expect(ordinary.update!(local: false, reply: true)).to eq true
      expect(ordinary.reload.local).to be false
      expect(ordinary.reply).to be true
      expect(public_status.update!(text: 'revised public', local: false)).to eq true

      legacy = project_for(user, body: 'legacy body')
      expect(legacy[:status].update!(text: 'revised legacy')).to eq true
      expect(legacy[:status].reload.text).to eq 'revised legacy'
      expect(legacy[:status].local).to be true
      ActiveRecord::Base.connection.execute("UPDATE statuses SET local = FALSE, reply = TRUE WHERE id = #{legacy[:status].id}")
      expect(legacy[:status].reload.local).to be false
      expect(legacy[:status].reply).to be true

      ActiveRecord::Base.connection.execute("UPDATE statuses SET text = 'sql revised external' WHERE id = #{status.id}")
      expect(status.reload.text).to eq 'sql revised external'
      expect(status.local).to be true
      expect(status.reply).to be false
    end

    it 'refuses to roll the guards back while a visibility 201 row exists' do
      external_project_for(user)
      expect(AcceptExternalVisibilityProjectionGuards::DOWN_PRECONDITION_SQL).to include('visibility = 201')
      expect_database_rejection(<<~SQL)
        IF EXISTS (SELECT 1 FROM statuses WHERE visibility = 201) THEN
          RAISE EXCEPTION 'refusing to roll back external visibility guards while visibility 201 statuses exist'
            USING ERRCODE = 'check_violation';
        END IF
      SQL
      body = ActiveRecord::Base.connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'external_status_projections_enforce_owner_account'")
      expect(body).to include('NOT IN (200, 201)')
    end

    it 'restores the pre-E1 functions when no visibility 201 row exists, then rolls that change back' do
      connection = ActiveRecord::Base.connection
      migration = AcceptExternalVisibilityProjectionGuards.new
      ActiveRecord::Base.transaction(requires_new: true) do
        migration.down
        body = connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'external_status_projections_enforce_owner_account'")
        expect(body).to include('IS DISTINCT FROM 200')
        expect(body).not_to include('NOT IN (200, 201)')
        field = connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'statuses_external_projection_field_guard'")
        expect(field).not_to include('OLD.visibility = 201')
        expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'statuses_external_visibility_shape_guard' AND NOT tgisinternal")).to be_nil
        expect(trigger_definition(connection, 'statuses_external_projection_field_guard')).not_to include('local, reply')

        migration.up
        restored = connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'external_status_projections_enforce_owner_account'")
        expect(restored).to include('NOT IN (200, 201)')
        expect(trigger_definition(connection, 'statuses_external_visibility_shape_guard')).to include('BEFORE INSERT OR UPDATE OF local, reply')
        expect(trigger_definition(connection, 'statuses_external_projection_field_guard')).to include('local, reply')
        raise ActiveRecord::Rollback
      end

      body = connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'external_status_projections_enforce_owner_account'")
      expect(body).to include('NOT IN (200, 201)')
      expect(connection.select_value("SELECT 1 FROM pg_trigger WHERE tgname = 'statuses_external_visibility_shape_guard' AND NOT tgisinternal")).to eq 1
      expect(trigger_definition(connection, 'statuses_external_visibility_shape_guard')).to include('BEFORE INSERT OR UPDATE OF local, reply')
      expect(trigger_definition(connection, 'statuses_external_projection_field_guard')).to include('local, reply')
    end

    def trigger_definition(connection, name)
      connection.select_value(<<~SQL.squish)
        SELECT pg_get_triggerdef(oid) FROM pg_trigger
        WHERE tgname = #{connection.quote(name)} AND NOT tgisinternal
      SQL
    end
  end

  describe 'query count' do
    it 'keeps marker reads flat for twenty ordinary ids and a mixed page' do
      ordinary = Array.new(20) { Fabricate(:status, account: stranger.account, text: 'Ordinary public') }
      legacy = Array.new(10) { |index| project_for(user, body: "Legacy #{index}")[:status] }
      external = Array.new(10) { |index| external_project_for(user, body: "External #{index}")[:status] }

      one = marker_selects_during do
        Status.permitted_statuses_from_ids([ordinary.first.id], stranger.account_id, viewer_user_id: stranger.id)
      end
      many = marker_selects_during do
        found = Status.permitted_statuses_from_ids(ordinary.map(&:id), stranger.account_id, viewer_user_id: stranger.id)
        expect(found.map(&:id)).to match_array(ordinary.map(&:id))
      end
      expect(many).to eq one
      expect(many).to be <= 2

      mixed_ids = legacy.map(&:id) + external.map(&:id)
      mixed = marker_selects_during do
        found = Status.permitted_statuses_from_ids(mixed_ids, user.account_id, viewer_user_id: user.id)
        expect(found.map(&:id)).to match_array(mixed_ids)
      end
      hidden = marker_selects_during do
        found = Status.permitted_statuses_from_ids(mixed_ids, roommate.account_id, viewer_user_id: roommate.id)
        expect(found).to be_empty
      end
      expect(mixed).to eq many
      expect(hidden).to eq many
    end

    it 'explains the non-projection predicate with the status-id index on this small database' do
      connection = ActiveRecord::Base.connection
      plan = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        connection.execute('SET LOCAL enable_seqscan = off')
        plan = connection.select_values(<<~SQL).join("\n")
          EXPLAIN SELECT statuses.id FROM statuses
          WHERE #{ExternalBridge::ProjectionPrivacy::NOT_PROJECTION_SQL}
            AND statuses.id IN (1, 2, 3)
        SQL
        raise ActiveRecord::Rollback
      end

      expect(plan).to include('visibility')
      expect(plan).to include('201')
      expect(plan).to include('index_external_status_projections_on_status_id')
      target = '/opt/cursor/artifacts/external-visibility-explain.txt'
      File.write(target, plan) if File.directory?('/opt/cursor/artifacts')
    end

    def marker_selects_during(&block)
      queries = []
      callback = lambda do |*, payload|
        queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:sql].include?('SCHEMA')
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      queries.count { |sql| sql.match?(/from\s+"?external_status_projections"?/i) && !sql.match?(/from\s+"?statuses"?/i) }
    end
  end
end
# rubocop:enable Metrics/BlockLength
