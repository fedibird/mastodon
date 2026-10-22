# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'pg'
require Rails.root.join('db/migrate/20261021180000_permit_external_visibility_projection_transition.rb')
require Rails.root.join('db/migrate/20261022120000_reinstall_external_visibility_migrate_function.rb')

# The application test role in this environment is a superuser. These examples
# use that connection only to create a NOSUPERUSER database owner. schema:load
# and the E2 migrations run on a fresh connection as that owner.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'external visibility migrate function without superuser' do
  self.use_transactional_tests = false

  let(:role_name) { 'eb_e2_nonsuper' }
  let(:database_name) { 'eb_e2_nonsuper_load_test' }

  after do
    drop_privilege_probe
  end

  it 'loads the schema and migrates E1 to E2 as a normal database owner' do
    password = SecureRandom.hex(24)
    admin = ActiveRecord::Base.connection
    admin_role = admin.select_one(<<~SQL.squish)
      SELECT current_user AS role, r.rolsuper, r.rolcreatedb, r.rolcreaterole,
             current_setting('server_version') AS version
      FROM pg_roles r WHERE r.rolname = current_user
    SQL
    drop_privilege_probe
    admin.execute("CREATE ROLE #{role_name} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT LOGIN PASSWORD #{admin.quote(password)}")
    admin.execute("CREATE DATABASE #{database_name} OWNER #{role_name}")

    load_out, load_status = Open3.capture2e(owner_env(password), 'bundle', 'exec', 'rake', 'db:schema:load', chdir: Rails.root.to_s)
    expect(load_status).to be_success, redact(load_out, password)

    owner = owner_connection(password)
    flags = owner.exec(<<~SQL).first
      SELECT current_user, rolsuper, rolcreatedb, rolcreaterole
      FROM pg_roles WHERE rolname = current_user
    SQL
    expect(flags['current_user']).to eq role_name
    expect(flags['rolsuper']).to eq 'f'
    expect(flags['rolcreatedb']).to eq 'f'
    parameter_acl = owner.exec("SELECT count(*) FROM pg_parameter_acl WHERE parname = 'fedibird.external_visibility_migration'").getvalue(0, 0)
    expect(parameter_acl.to_i).to eq 0
    expect do
      owner.exec(<<~SQL)
        CREATE FUNCTION eb_e2_rejected_guc() RETURNS void
        LANGUAGE plpgsql
        SET fedibird.external_visibility_migration TO 'off'
        AS $$ BEGIN NULL; END $$
      SQL
    end.to raise_error(PG::InsufficientPrivilege, /fedibird.external_visibility_migration/)

    proconfig = owner.exec("SELECT proconfig::text FROM pg_proc WHERE proname = 'external_visibility_migrate_status'").getvalue(0, 0)
    body = owner.exec("SELECT prosrc FROM pg_proc WHERE proname = 'external_visibility_migrate_status'").getvalue(0, 0)
    expect(proconfig).to be_nil
    expect(body).to include('query_canceled')
    expect(body).to include("set_config('fedibird.external_visibility_migration', previous, true)")

    with_owner_connection(password) do |connection|
      expect(connection.select_value('SELECT current_user')).to eq role_name
      expect(connection.select_value('SELECT rolsuper FROM pg_roles WHERE rolname = current_user')).to be_in([false, 'f'])

      e2 = PermitExternalVisibilityProjectionTransition.new
      follow_up = ReinstallExternalVisibilityMigrateFunction.new
      # db:migrate wraps each revision in a transaction. Calling #up/#down
      # directly would make SET LOCAL lock_timeout a no-op warning.
      connection.transaction { e2.down }
      expect(connection.select_value("SELECT 1 FROM pg_proc WHERE proname = 'external_visibility_migrate_status'")).to be_nil
      connection.transaction { e2.up }
      connection.transaction { follow_up.up }
      expect(ExternalBridge::VisibilitySwitch.transition_ready?).to be true
      expect(connection.select_value("SELECT proconfig::text FROM pg_proc WHERE proname = 'external_visibility_migrate_status'")).to be_nil

      Setting.external_bridge_external_visibility = false
      user = Fabricate(:user, account: Fabricate(:account, username: "e2priv#{SecureRandom.hex(4)}"))
      legacy = project_for(user, body: 'Privilege body')
      second = project_for(user, body: 'Second privilege body')
      third = project_for(user, body: 'Third privilege body')
      ordinary = PostStatusService.new.call(user.account, text: 'Ordinary privilege', visibility: 'personal')
      permit = -> { connection.select_value("SELECT current_setting('fedibird.external_visibility_migration', true)") }

      expect(permit.call).to be_nil
      expect(connection.select_value("SELECT external_visibility_migrate_status(#{legacy[:status].id})").to_i).to eq 1
      expect(legacy[:status].reload.visibility).to eq 'external'
      expect(permit.call.to_s).not_to include("#{legacy[:status].id}:")
      expect(permit.call.presence).to be_nil
      expect_database_rejection("UPDATE statuses SET visibility = 201 WHERE id = #{second[:status].id}")
      expect(second[:status].reload.visibility).to eq 'personal'

      connection.transaction do
        connection.select_value("SELECT set_config('fedibird.external_visibility_migration', 'off', true)")
        connection.select_value("SELECT external_visibility_migrate_status(#{second[:status].id})")
        expect(permit.call).to eq 'off'
        expect(second[:status].reload.visibility).to eq 'external'
        raise ActiveRecord::Rollback
      end
      expect(second[:status].reload.visibility).to eq 'personal'
      expect(permit.call.presence).to be_nil

      connection.transaction do
        connection.select_value("SELECT set_config('fedibird.external_visibility_migration', 'caller-held', true)")
        connection.select_value("SELECT external_visibility_migrate_status(#{second[:status].id})")
        expect(permit.call).to eq 'caller-held'
        expect_database_rejection("UPDATE statuses SET text = 'smuggled', visibility = 201 WHERE id = #{third[:status].id}")
        expect(third[:status].reload.text).to eq 'Third privilege body'
        expect(third[:status].visibility).to eq 'personal'
        expect_database_rejection("UPDATE statuses SET visibility = 201 WHERE id = #{ordinary.id}")
        raise ActiveRecord::Rollback
      end

      connection.transaction do
        connection.select_value("SELECT set_config('fedibird.external_visibility_migration', 'before-call', true)")
        expect do
          connection.transaction(requires_new: true) do
            connection.select_value("SELECT external_visibility_migrate_status(#{ordinary.id})")
          end
        end.to raise_error(ActiveRecord::StatementInvalid)
        expect(permit.call).to eq 'before-call'
        expect(ordinary.reload.visibility).to eq 'personal'
        raise ActiveRecord::Rollback
      end

      holder = owner_connection(password)
      holder.exec('BEGIN')
      holder.exec("SELECT id FROM statuses WHERE id = #{second[:status].id} FOR UPDATE")
      expect do
        connection.transaction do
          connection.execute("SET LOCAL statement_timeout = '400ms'")
          connection.select_value("SELECT external_visibility_migrate_status(#{second[:status].id})")
        end
      end.to raise_error(ActiveRecord::QueryCanceled)
      expect(second[:status].reload.visibility).to eq 'personal'
      expect(permit.call.presence).to be_nil
      holder.exec('ROLLBACK')
      holder.close

      connection.transaction { e2.down }
      connection.transaction { e2.up }
      connection.transaction { follow_up.down }
      expect(connection.select_value("SELECT proconfig::text FROM pg_proc WHERE proname = 'external_visibility_migrate_status'")).to be_nil
      expect(ExternalBridge::VisibilitySwitch.transition_ready?).to be true
      expect(connection.select_value("SELECT external_visibility_migrate_status(#{second[:status].id})").to_i).to eq 1
      expect(second[:status].reload.visibility).to eq 'external'
      expect(permit.call.to_s).not_to include("#{second[:status].id}:")
      expect_database_rejection("UPDATE statuses SET visibility = 200 WHERE id = #{second[:status].id}")
    end

    File.write(
      '/opt/cursor/artifacts/e2-privilege-check.txt',
      <<~REPORT
        server_version=#{admin_role['version']}
        admin_role=#{admin_role['role']} rolsuper=#{admin_role['rolsuper']} rolcreatedb=#{admin_role['rolcreatedb']} rolcreaterole=#{admin_role['rolcreaterole']}
        schema_role=#{role_name} rolsuper=false rolcreatedb=false parameter_acl=0
        schema_load=success migration=E1-down E2-up follow-up-up E1-down E2-up follow-up-down
        canonical_200_to_201=1
      REPORT
    )
  end

  def owner_env(password)
    {
      'RAILS_ENV' => 'test',
      'DB_NAME' => 'eb_e2_nonsuper_load',
      'DB_USER' => role_name,
      'DB_PASS' => password,
      'DB_HOST' => 'localhost',
      'DB_PORT' => '5432',
    }
  end

  def owner_connection(password)
    PG.connect(host: 'localhost', port: 5432, dbname: database_name, user: role_name, password: password)
  end

  def with_owner_connection(password)
    ActiveRecord::Base.establish_connection(
      adapter: 'postgresql',
      host: 'localhost',
      port: 5432,
      database: database_name,
      username: role_name,
      password: password,
      encoding: 'unicode'
    )
    yield ActiveRecord::Base.connection
  ensure
    ActiveRecord::Base.establish_connection(:test)
  end

  def drop_privilege_probe
    connection = ActiveRecord::Base.connection
    return unless connection.select_value('SELECT rolsuper FROM pg_roles WHERE rolname = current_user').in?([true, 't'])

    if connection.select_value("SELECT 1 FROM pg_database WHERE datname = #{connection.quote(database_name)}")
      connection.select_value(<<~SQL)
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE datname = #{connection.quote(database_name)} AND pid <> pg_backend_pid()
      SQL
      connection.execute("DROP DATABASE IF EXISTS #{database_name}")
    end
    connection.execute("DROP ROLE IF EXISTS #{role_name}") if connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = #{connection.quote(role_name)}")
  end

  def redact(text, password)
    text.to_s.gsub(password, '[redacted]')
  end
end
# rubocop:enable Metrics/BlockLength
