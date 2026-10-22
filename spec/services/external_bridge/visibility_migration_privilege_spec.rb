# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'
require 'open3'
require 'pg'
require Rails.root.join('db/migrate/20261021180000_permit_external_visibility_projection_transition.rb')
require Rails.root.join('db/migrate/20261022120000_reinstall_external_visibility_migrate_function.rb')

# Opt-in harness for proving schema:load as a NOSUPERUSER database owner.
# A normal suite does not create or drop roles. Set E2_PRIVILEGE_ADMIN=1 to run
# the live checks. Optional E2_PRIVILEGE_ADMIN_USER and
# E2_PRIVILEGE_ADMIN_PASSWORD select another admin on the same configured
# cluster. E2_PRIVILEGE_REPORT_DIR chooses the report directory.
class VisibilityMigrationPrivilegeProbe
  class NotOptedIn < StandardError; end
  class AdminUnavailable < StandardError; end

  IDENT = /\Aeb_e2_[0-9a-f]{16}(_test)?\z/
  PROBE_STEM = /\Aeb_e2_[0-9a-f]{16}\z/
  SENTINEL_IDENT = /\Aeb_e2_sentinel_[0-9a-f]{16}\z/
  REFUSAL = 'refusing schema load before DDL: resolved connection does not match the probe'
  SESSION_REFUSAL = 'refusing schema load before DDL: connected session does not match the probe'
  CAPABILITY_SQL = <<~SQL.squish
    SELECT current_user AS role, r.rolsuper, r.rolcreatedb, r.rolcreaterole,
           current_setting('server_version') AS version
    FROM pg_roles r WHERE r.rolname = current_user
  SQL

  attr_reader :role_name, :database_name, :created_role, :created_database

  def self.generate(admin_opt_in:)
    new(suffix: SecureRandom.hex(8), admin_opt_in: admin_opt_in)
  end

  def self.opt_in?(value = ENV.fetch('E2_PRIVILEGE_ADMIN', nil))
    value == '1'
  end

  def self.refusal_reason
    'E2_PRIVILEGE_ADMIN is not 1, so this example does not CREATE or DROP. ' \
      'The privilege schema load is a separate opt-in job and this skip is not a pass.'
  end

  def self.skip_reason
    return if opt_in?

    refusal_reason
  end

  def self.capable?(row)
    return false if row.blank?

    truthy?(row['rolsuper']) || (truthy?(row['rolcreaterole']) && truthy?(row['rolcreatedb']))
  end

  def self.truthy?(value)
    value == true || value == 't'
  end

  def self.stringify(row)
    row.to_h.transform_keys(&:to_s)
  end

  def self.cluster_from(config)
    values = config.symbolize_keys
    {
      host: values[:host].presence,
      port: values[:port].presence,
      sslmode: values[:sslmode].presence,
      database: values[:database],
    }
  end

  def self.connect_options(cluster:, dbname:, user:, password:)
    options = { dbname: dbname, user: user, password: password }
    options[:host] = cluster[:host] if cluster[:host].present?
    options[:port] = cluster[:port] if cluster[:port].present?
    options[:sslmode] = cluster[:sslmode] if cluster[:sslmode].present?
    options
  end

  def self.ar_config(cluster:, database:, user:, password:)
    options = connect_options(cluster: cluster, dbname: database, user: user, password: password)
    {
      adapter: 'postgresql',
      encoding: 'unicode',
      database: options[:dbname],
      username: options[:user],
      password: options[:password],
    }.tap do |config|
      config[:host] = options[:host] if options.key?(:host)
      config[:port] = options[:port] if options.key?(:port)
      config[:sslmode] = options[:sslmode] if options.key?(:sslmode)
    end
  end

  # Spawn merges this hash onto the parent environment. A nil value unsets an
  # inherited host or port so a blank database.yml setting stays a socket.
  # DATABASE_URL and every *_DATABASE_URL are set to the probe, not deleted.
  # Dotenv.load uses ENV[key] ||= value, so a deleted URL would come back from
  # a file, while a URL that is already set stays pointed at the probe.
  def self.child_env(base_env:, cluster:, db_name:, user:, password:)
    raise ArgumentError, 'refusing a probe name this harness did not generate' unless db_name.match?(PROBE_STEM)
    raise ArgumentError, 'refusing an empty probe password' if password.blank?

    database = "#{db_name}_test"
    url = probe_database_url(cluster: cluster, database: database, user: user, password: password)
    env = base_env.to_h.merge(
      'RAILS_ENV' => 'test',
      'DB_NAME' => db_name,
      'DB_USER' => user,
      'DB_PASS' => password,
      'TEST_ENV_NUMBER' => '',
      'DB_HOST' => cluster[:host].present? ? cluster[:host].to_s : nil,
      'DB_PORT' => cluster[:port].present? ? cluster[:port].to_s : nil,
      'DB_SSLMODE' => cluster[:sslmode].present? ? cluster[:sslmode].to_s : nil,
      'E2_PRIVILEGE_EXPECT_DATABASE' => database,
      'E2_PRIVILEGE_EXPECT_USER' => user,
      'E2_PRIVILEGE_EXPECT_HOST' => cluster[:host].present? ? cluster[:host].to_s : nil,
      'E2_PRIVILEGE_EXPECT_PORT' => cluster[:port].present? ? cluster[:port].to_s : nil
    )
    env.each_key { |key| env[key] = url if key == 'DATABASE_URL' || key.end_with?('_DATABASE_URL') }
    env['DATABASE_URL'] = url
    env['PRIMARY_DATABASE_URL'] = url
    env
  end

  def self.probe_database_url(cluster:, database:, user:, password:)
    authority = if cluster[:host].present?
                  cluster[:port].present? ? "#{cluster[:host]}:#{cluster[:port]}" : cluster[:host].to_s
                else
                  ''
                end
    query = cluster[:sslmode].present? ? "?sslmode=#{encode_url_component(cluster[:sslmode])}" : ''
    "postgresql://#{encode_url_component(user)}:#{encode_url_component(password)}@#{authority}/#{encode_url_component(database)}#{query}"
  end

  def self.encode_url_component(value)
    URI.encode_www_form_component(value.to_s).tr('+', '%20')
  end

  def self.target_matches?(config, database:, user:, host:, port:)
    return false if config.blank?

    values = config.symbolize_keys
    values[:database].to_s == database.to_s &&
      values[:username].to_s == user.to_s &&
      values[:host].to_s == host.to_s &&
      values[:port].to_s == port.to_s
  end

  # Reads config/database.yml and applies Rails 6.1 URL precedence while env
  # is installed. Does not connect and does not keep the swapped variables.
  def self.resolved_test_config(env)
    with_env(env) do
      raw = Rails.application.config.database_configuration
      ActiveRecord::DatabaseConfigurations.new(raw).configs_for(env_name: 'test', name: 'primary')&.configuration_hash
    end
  end

  def self.with_env(env)
    keys = env.keys
    previous = {}
    keys.each { |key| previous[key] = ENV[key] if ENV.key?(key) }
    keys.each do |key|
      value = env[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value.to_s
    end
    yield
  ensure
    keys.each { |key| ENV.delete(key) }
    previous.each { |key, value| ENV[key] = value }
  end

  def self.schema_load_source
    <<~RUBY
      require './config/application'

      expected_database = ENV.fetch('E2_PRIVILEGE_EXPECT_DATABASE')
      expected_user = ENV.fetch('E2_PRIVILEGE_EXPECT_USER')
      expected_host = ENV['E2_PRIVILEGE_EXPECT_HOST'].to_s
      expected_port = ENV['E2_PRIVILEGE_EXPECT_PORT'].to_s

      Rails.application.config.before_initialize do
        raw = Rails.application.config.database_configuration
        resolved = ActiveRecord::DatabaseConfigurations.new(raw).configs_for(env_name: 'test', name: 'primary')
        hash = resolved&.configuration_hash&.symbolize_keys || {}
        matched = hash[:database].to_s == expected_database &&
                  hash[:username].to_s == expected_user &&
                  hash[:host].to_s == expected_host &&
                  hash[:port].to_s == expected_port
        unless matched
          warn #{REFUSAL.inspect}
          exit! 1
        end
      end

      Rails.application.initialize!

      actual = ActiveRecord::Base.connection.select_one('SELECT current_database() AS database, current_user AS role')
      unless actual['database'] == expected_database && actual['role'] == expected_user
        warn #{SESSION_REFUSAL.inspect}
        exit! 1
      end

      ActiveRecord::Tasks::DatabaseTasks.load_schema_current(:ruby, Rails.root.join('db/schema.rb').to_s)
    RUBY
  end

  def self.quote_sentinel(name)
    raise ArgumentError, 'refusing an unexpected sentinel name' unless name.match?(SENTINEL_IDENT)

    %("#{name}")
  end

  def self.redact_env(text, env)
    secrets = env.filter_map do |key, value|
      next if value.nil? || value.empty?
      next unless key.match?(/URL|PASS|PASSWORD|SECRET/)

      value
    end
    redact(text, *secrets)
  end

  def self.open_admin_session(cluster)
    admin_user = ENV.fetch('E2_PRIVILEGE_ADMIN_USER', '').to_s
    return AdminSession.new(ActiveRecord::Base.connection, owned: false) if admin_user.empty?

    password = ENV.fetch('E2_PRIVILEGE_ADMIN_PASSWORD', nil)
    options = connect_options(cluster: cluster, dbname: cluster.fetch(:database), user: admin_user, password: password)
    AdminSession.new(PG.connect(options), owned: true)
  rescue PG::Error => e
    raise AdminUnavailable, redact(e.message, password)
  end

  def self.write_report(directory:, body:)
    write_report_file(directory.presence || Dir.mktmpdir('e2-privilege-'), body)
  rescue SystemCallError
    write_report_file(Dir.mktmpdir('e2-privilege-'), body)
  end

  def self.write_report_file(directory, body)
    FileUtils.mkdir_p(directory)
    path = File.join(directory, 'e2-privilege-check.txt')
    File.write(path, body)
    path
  end

  def self.redact(text, *secrets)
    secrets.compact.reduce(text.to_s) do |copy, secret|
      secret.empty? ? copy : copy.gsub(secret, '[redacted]')
    end
  end

  def self.redact_error(error, *secrets)
    text = redact(error.message, *secrets)
    return error if text == error.message

    cleaned = error.exception(text)
    cleaned.set_backtrace(error.backtrace)
    cleaned
  end

  def initialize(suffix:, admin_opt_in:)
    raise ArgumentError, 'suffix must be 16 hex characters' unless suffix.match?(/\A[0-9a-f]{16}\z/)

    @role_name = "eb_e2_#{suffix}"
    @database_name = "eb_e2_#{suffix}_test"
    @admin_opt_in = admin_opt_in
    @created_role = nil
    @created_database = nil
  end

  def schema_db_name
    role_name
  end

  def prepare!(session:, password:)
    raise NotOptedIn, self.class.refusal_reason unless @admin_opt_in
    raise ArgumentError, 'refusing an empty probe password' if password.blank?

    row = self.class.stringify(session.select_one(CAPABILITY_SQL) || {})
    unless self.class.capable?(row)
      detail = if row.empty?
                 'The admin connection returned no role attributes.'
               else
                 "#{row['role']} has rolsuper=#{row['rolsuper']} rolcreaterole=#{row['rolcreaterole']} rolcreatedb=#{row['rolcreatedb']}."
               end
      raise AdminUnavailable, "Refusing before CREATE ROLE or CREATE DATABASE. #{detail} CREATE ROLE needs CREATEROLE or superuser, and CREATE DATABASE needs CREATEDB or superuser."
    end

    session.execute(<<~SQL.squish)
      CREATE ROLE #{ident(role_name)} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT LOGIN
      PASSWORD #{session.quote(password)}
    SQL
    @created_role = role_name
    session.execute("CREATE DATABASE #{ident(database_name)} OWNER #{ident(role_name)}")
    @created_database = database_name
    row
  end

  def mark_created!
    @created_role = role_name
    @created_database = database_name
  end

  def drop_created!(session)
    if @created_database
      session.execute(<<~SQL.squish)
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE datname = #{session.quote(@created_database)} AND pid <> pg_backend_pid()
      SQL
      session.execute("DROP DATABASE IF EXISTS #{ident(@created_database)}")
      @created_database = nil
    end
    if @created_role
      session.execute("DROP ROLE IF EXISTS #{ident(@created_role)}")
      @created_role = nil
    end
  end

  def ident(name)
    raise ArgumentError, 'refusing an identifier this probe did not generate' unless name.match?(IDENT)

    %("#{name}")
  end

  class AdminSession
    def initialize(connection, owned:)
      @connection = connection
      @owned = owned
    end

    def select_one(sql)
      if pg_connection?
        @connection.exec(sql).first
      else
        @connection.select_one(sql)
      end
    end

    def execute(sql)
      if pg_connection?
        @connection.exec(sql)
      else
        @connection.execute(sql)
      end
    end

    def quote(value)
      if pg_connection?
        @connection.escape_literal(value.to_s)
      else
        @connection.quote(value)
      end
    end

    def database_exists?(name)
      !select_one("SELECT 1 FROM pg_database WHERE datname = #{quote(name)}").nil?
    end

    def role_exists?(name)
      !select_one("SELECT 1 FROM pg_roles WHERE rolname = #{quote(name)}").nil?
    end

    def fixed_names
      [
        select_one("SELECT rolname FROM pg_roles WHERE rolname = 'eb_e2_nonsuper'")&.[]('rolname'),
        select_one("SELECT datname FROM pg_database WHERE datname = 'eb_e2_nonsuper_load_test'")&.[]('datname'),
      ]
    end

    def close
      return unless @owned
      return if @connection.finished?

      @connection.close
    end

    private

    def pg_connection?
      defined?(PG::Connection) && @connection.is_a?(PG::Connection)
    end
  end
end

RSpec.describe VisibilityMigrationPrivilegeProbe do
  def recording_session(row)
    session = Object.new
    statements = []
    session.define_singleton_method(:select_one) { |_sql| row }
    session.define_singleton_method(:execute) { |sql| statements << sql }
    session.define_singleton_method(:quote) { |value| "'#{value}'" }
    session.define_singleton_method(:statements) { statements }
    session
  end

  it 'accepts only an explicit admin opt-in and a role that can create both objects' do
    expect(described_class.opt_in?('1')).to be true
    expect(described_class.opt_in?('true')).to be false
    expect(described_class.opt_in?(nil)).to be false
    expect(described_class.opt_in?('')).to be false
    expect(described_class.capable?('rolsuper' => true, 'rolcreaterole' => false, 'rolcreatedb' => false)).to be true
    expect(described_class.capable?('rolsuper' => 't', 'rolcreaterole' => 'f', 'rolcreatedb' => 'f')).to be true
    expect(described_class.capable?('rolsuper' => false, 'rolcreaterole' => true, 'rolcreatedb' => true)).to be true
    expect(described_class.capable?('rolsuper' => false, 'rolcreaterole' => false, 'rolcreatedb' => true)).to be false
    expect(described_class.capable?('rolsuper' => 'f', 'rolcreaterole' => 't', 'rolcreatedb' => 'f')).to be false
    expect(described_class.capable?(nil)).to be false
  end

  it 'does not issue admin DDL when the suite has no privilege admin opt-in' do
    session = recording_session('rolsuper' => true, 'rolcreatedb' => true, 'rolcreaterole' => true)
    probe = described_class.new(suffix: '0123456789abcdef', admin_opt_in: false)

    expect { probe.prepare!(session: session, password: 'generated') }.to raise_error(described_class::NotOptedIn, /not a pass/)
    expect(session.statements).to be_empty
    expect(probe.created_role).to be_nil
    expect(probe.created_database).to be_nil
    probe.drop_created!(session)
    expect(session.statements).to be_empty
  end

  it 'refuses before DDL when the opted-in admin cannot create a role and a database' do
    session = recording_session('role' => 'app', 'rolsuper' => false, 'rolcreatedb' => true, 'rolcreaterole' => false, 'version' => '16')
    probe = described_class.new(suffix: '0123456789abcdef', admin_opt_in: true)

    expect { probe.prepare!(session: session, password: 'generated') }.to raise_error(described_class::AdminUnavailable, /CREATE ROLE/)
    expect(session.statements).to be_empty
    expect(probe.created_role).to be_nil
  end

  it 'keeps parallel probe cleanup disjoint and ignores historical fixed names' do
    first = described_class.new(suffix: '0123456789abcdef', admin_opt_in: true)
    second = described_class.new(suffix: 'fedcba9876543210', admin_opt_in: true)
    unmarked = described_class.new(suffix: '0011223344556677', admin_opt_in: true)
    first.mark_created!
    second.mark_created!
    session = recording_session(nil)

    first.drop_created!(session)
    joined = session.statements.join("\n")

    expect(joined).to include(first.database_name)
    expect(joined).to include(first.role_name)
    expect(joined).to include('pg_terminate_backend')
    expect(joined).not_to include(second.database_name)
    expect(joined).not_to include(second.role_name)
    expect(joined).not_to include('eb_e2_nonsuper')
    expect(joined).not_to include('eb_e2_sentinel_0123456789abcdef')
    expect(second.created_database).to eq second.database_name
    expect(second.created_role).to eq second.role_name
    expect { first.ident('eb_e2_nonsuper') }.to raise_error(ArgumentError)
    expect { first.ident('eb_e2_nonsuper_load_test') }.to raise_error(ArgumentError)

    unmarked.drop_created!(session)
    expect(session.statements.join("\n")).to eq joined
  end

  it 'follows the configured cluster and does not invent localhost:5432' do
    blank = described_class.connect_options(
      cluster: { host: nil, port: nil, sslmode: 'prefer' },
      dbname: 'unused', user: 'unused', password: 'unused'
    )
    expect(blank.keys).to contain_exactly(:dbname, :user, :password, :sslmode)
    expect(blank[:sslmode]).to eq 'prefer'

    env = described_class.child_env(
      base_env: { 'PATH' => '/usr/bin', 'DB_HOST' => 'db.internal', 'DB_PORT' => '5433', 'DB_SSLMODE' => 'require' },
      cluster: { host: nil, port: '', sslmode: 'prefer' },
      db_name: 'eb_e2_0123456789abcdef',
      user: 'eb_e2_0123456789abcdef',
      password: 'generated-secret'
    )
    expect(env['DB_HOST']).to be_nil
    expect(env['DB_PORT']).to be_nil
    expect(env['DB_SSLMODE']).to eq 'prefer'
    expect(env['DB_NAME']).to eq 'eb_e2_0123456789abcdef'
    expect(env['DB_USER']).to eq 'eb_e2_0123456789abcdef'
    expect(env['TEST_ENV_NUMBER']).to eq ''
    expect(env['PATH']).to eq '/usr/bin'
    expect(env['RAILS_ENV']).to eq 'test'

    present = described_class.child_env(
      base_env: {},
      cluster: { host: '10.0.0.8', port: 5434, sslmode: nil },
      db_name: 'eb_e2_0123456789abcdef',
      user: 'eb_e2_0123456789abcdef',
      password: 'generated-secret'
    )
    expect(present['DB_HOST']).to eq '10.0.0.8'
    expect(present['DB_PORT']).to eq '5434'
    expect(present['DB_SSLMODE']).to be_nil

    config = ActiveRecord::Base.connection_db_config.configuration_hash
    options = described_class.connect_options(
      cluster: described_class.cluster_from(config),
      dbname: 'unused', user: 'unused', password: 'unused'
    )
    configured = config.symbolize_keys
    if configured[:host].present?
      expect(options[:host]).to eq configured[:host]
    else
      expect(options).not_to have_key(:host)
    end
    if configured[:port].present?
      expect(options[:port]).to eq configured[:port]
    else
      expect(options).not_to have_key(:port)
    end
  end

  it 'resolves the child to the probe for every inherited database URL' do
    probe_user = 'eb_e2_0123456789abcdef'
    probe_database = "#{probe_user}_test"
    cluster = { host: 'db.example', port: 5432, sslmode: 'prefer' }
    foreign = {
      none: {},
      database_url: { 'DATABASE_URL' => 'postgresql://app:secret@db.example:5432/existing_test' },
      primary_database_url: { 'PRIMARY_DATABASE_URL' => 'postgresql://app:secret@db.example:5432/primary_existing' },
      both: {
        'DATABASE_URL' => 'postgresql://app:secret@db.example:5432/existing_test',
        'PRIMARY_DATABASE_URL' => 'postgresql://app:secret@db.example:5432/primary_existing',
        'REPLICA_DATABASE_URL' => 'postgresql://app:secret@db.example:5432/replica_existing',
      },
    }

    foreign.each do |label, inherited|
      parent = inherited.merge('PATH' => '/usr/bin')
      snapshot = parent.dup
      env = described_class.child_env(
        base_env: parent,
        cluster: cluster,
        db_name: probe_user,
        user: probe_user,
        password: 'generated-secret'
      )

      expect(parent).to eq(snapshot), label.to_s
      resolved = described_class.resolved_test_config(env)
      expect(described_class.target_matches?(resolved, database: probe_database, user: probe_user, host: 'db.example', port: 5432)).to be(true), label.to_s
      expect(resolved[:database]).not_to eq('existing_test'), label.to_s
      expect(resolved[:database]).not_to eq('primary_existing'), label.to_s
      expect(resolved[:database]).not_to eq('replica_existing'), label.to_s
      %w[DATABASE_URL PRIMARY_DATABASE_URL REPLICA_DATABASE_URL].each do |key|
        next unless env.key?(key)

        database = ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver.new(env.fetch(key)).to_hash[:database]
        expect(database).to eq(probe_database), "#{label} #{key}"
      end
    end

    blank = described_class.child_env(
      base_env: {
        'DATABASE_URL' => 'postgresql://app:secret@db.example:5432/existing_test',
        'DB_HOST' => 'db.internal',
        'DB_PORT' => '5433',
      },
      cluster: { host: nil, port: nil, sslmode: 'prefer' },
      db_name: probe_user,
      user: probe_user,
      password: 'generated-secret'
    )
    blank_resolved = described_class.resolved_test_config(blank)
    expect(described_class.target_matches?(blank_resolved, database: probe_database, user: probe_user, host: nil, port: nil)).to be true
    expect(blank_resolved[:database]).not_to eq 'existing_test'

    kept = described_class.child_env(
      base_env: { 'DATABASE_URL' => 'postgresql://app:secret@db.example:5432/existing_test' },
      cluster: cluster,
      db_name: probe_user,
      user: probe_user,
      password: 'generated-secret'
    )
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.env'), "DATABASE_URL=postgresql://app:secret@db.example:5432/from_file\nPRIMARY_DATABASE_URL=postgresql://app:secret@db.example:5432/from_file_primary\n")
      described_class.with_env(kept) do
        Dotenv.load(File.join(dir, '.env'))
        reloaded = described_class.resolved_test_config(ENV.to_h.slice(
          'RAILS_ENV', 'DB_NAME', 'DB_USER', 'DB_PASS', 'DB_HOST', 'DB_PORT', 'DB_SSLMODE', 'TEST_ENV_NUMBER',
          'DATABASE_URL', 'PRIMARY_DATABASE_URL'
        ))
        expect(reloaded[:database]).to eq probe_database
        expect(reloaded[:username]).to eq probe_user
        expect(reloaded[:database]).not_to eq 'from_file'
        expect(reloaded[:database]).not_to eq 'from_file_primary'
      end
    end
  end

  it 'writes the privilege report without requiring a cursor artifacts directory' do
    Dir.mktmpdir do |dir|
      path = described_class.write_report(directory: dir, body: "schema_load=success\n")
      expect(File.read(path)).to eq("schema_load=success\n")
      expect(path).to start_with(dir)
    end

    temporary = described_class.write_report(directory: nil, body: "schema_load=success\n")
    expect(File.read(temporary)).to eq("schema_load=success\n")
    expect(temporary).not_to include('/opt/cursor/artifacts')
    FileUtils.remove_entry(File.dirname(temporary))

    Dir.mktmpdir do |dir|
      blocker = File.join(dir, 'not-a-directory')
      File.write(blocker, 'x')
      path = described_class.write_report(directory: blocker, body: "schema_load=success\n")
      expect(File.read(path)).to eq("schema_load=success\n")
      expect(path).not_to start_with(blocker)
      FileUtils.remove_entry(File.dirname(path))
    end
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe 'external visibility migrate function without superuser' do
  self.use_transactional_tests = false

  def cluster
    @cluster ||= VisibilityMigrationPrivilegeProbe.cluster_from(ActiveRecord::Base.connection_db_config.configuration_hash)
  end

  def close_clients(clients)
    clients.each do |client|
      next if client.finished?

      client.close
    rescue StandardError
      nil
    end
  end

  def drop_probe(probe)
    return if probe.created_database.nil? && probe.created_role.nil?

    original = $!
    ActiveRecord::Base.establish_connection(:test)
    cleanup = VisibilityMigrationPrivilegeProbe.open_admin_session(cluster)
    begin
      probe.drop_created!(cleanup)
    ensure
      cleanup.close
    end
  rescue StandardError => e
    raise original if original

    raise VisibilityMigrationPrivilegeProbe.redact_error(e)
  end

  def app_login
    config = ActiveRecord::Base.connection_db_config.configuration_hash.symbolize_keys
    { user: config[:username].to_s, password: config[:password].to_s }
  end

  def install_sentinel_marker!(name)
    login = app_login
    connection = PG.connect(
      VisibilityMigrationPrivilegeProbe.connect_options(
        cluster: cluster, dbname: name, user: login[:user], password: login[:password]
      )
    )
    connection.exec('CREATE TABLE e2_sentinel (id integer primary key)')
    connection.exec('INSERT INTO e2_sentinel (id) VALUES (1)')
  ensure
    connection&.close unless connection&.finished?
  end

  def sentinel_count(name)
    login = app_login
    connection = PG.connect(
      VisibilityMigrationPrivilegeProbe.connect_options(
        cluster: cluster, dbname: name, user: login[:user], password: login[:password]
      )
    )
    connection.exec('SELECT count(*) FROM e2_sentinel').getvalue(0, 0).to_i
  ensure
    connection&.close unless connection&.finished?
  end

  def probe_schema_loaded?(probe, password)
    connection = PG.connect(
      VisibilityMigrationPrivilegeProbe.connect_options(
        cluster: cluster, dbname: probe.database_name, user: probe.role_name, password: password
      )
    )
    !connection.exec("SELECT to_regclass('public.schema_migrations')").getvalue(0, 0).nil?
  ensure
    connection&.close unless connection&.finished?
  end

  def drop_sentinel!(name)
    return if name.nil?

    original = $!
    ActiveRecord::Base.establish_connection(:test)
    cleanup = VisibilityMigrationPrivilegeProbe.open_admin_session(cluster)
    begin
      cleanup.execute(<<~SQL.squish)
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE datname = #{cleanup.quote(name)} AND pid <> pg_backend_pid()
      SQL
      cleanup.execute("DROP DATABASE IF EXISTS #{VisibilityMigrationPrivilegeProbe.quote_sentinel(name)}")
    rescue StandardError => e
      raise original if original

      raise VisibilityMigrationPrivilegeProbe.redact_error(e)
    ensure
      cleanup.close
    end
  end

  def run_schema_child(env)
    output, status = Open3.capture2e(
      env,
      'bundle', 'exec', 'ruby', '-e', VisibilityMigrationPrivilegeProbe.schema_load_source,
      chdir: Rails.root.to_s
    )
    [VisibilityMigrationPrivilegeProbe.redact_env(output, env), status]
  end

  it 'drops only the probe resources this run created' do
    skip VisibilityMigrationPrivilegeProbe.skip_reason if VisibilityMigrationPrivilegeProbe.skip_reason

    password_a = SecureRandom.hex(24)
    password_b = SecureRandom.hex(24)
    probe_a = VisibilityMigrationPrivilegeProbe.generate(admin_opt_in: true)
    probe_b = VisibilityMigrationPrivilegeProbe.generate(admin_opt_in: true)
    admin = nil
    fixed_before = nil
    begin
      admin = VisibilityMigrationPrivilegeProbe.open_admin_session(cluster)
      fixed_before = admin.fixed_names
      probe_a.prepare!(session: admin, password: password_a)
      probe_b.prepare!(session: admin, password: password_b)
      probe_a.drop_created!(admin)

      expect(admin.database_exists?(probe_a.database_name)).to be false
      expect(admin.role_exists?(probe_a.role_name)).to be false
      expect(admin.database_exists?(probe_b.database_name)).to be true
      expect(admin.role_exists?(probe_b.role_name)).to be true
      expect(admin.fixed_names).to eq fixed_before
    rescue StandardError => e
      raise VisibilityMigrationPrivilegeProbe.redact_error(e, password_a, password_b)
    ensure
      admin&.close
      ActiveRecord::Base.establish_connection(:test)
      begin
        drop_probe(probe_b)
      ensure
        drop_probe(probe_a)
      end
    end
  end

  it 'loads the schema and migrates E1 to E2 as a normal database owner' do
    skip VisibilityMigrationPrivilegeProbe.skip_reason if VisibilityMigrationPrivilegeProbe.skip_reason

    probe = VisibilityMigrationPrivilegeProbe.generate(admin_opt_in: true)
    password = SecureRandom.hex(24)
    admin_password = ENV.fetch('E2_PRIVILEGE_ADMIN_PASSWORD', nil)
    admin = nil
    clients = []
    sentinel_name = nil
    child = nil
    begin
      admin = VisibilityMigrationPrivilegeProbe.open_admin_session(cluster)
      admin_row = probe.prepare!(session: admin, password: password)
      candidate = "eb_e2_sentinel_#{SecureRandom.hex(8)}"
      admin.execute("CREATE DATABASE #{VisibilityMigrationPrivilegeProbe.quote_sentinel(candidate)}")
      sentinel_name = candidate
      install_sentinel_marker!(sentinel_name)
      login = app_login
      sentinel_url = VisibilityMigrationPrivilegeProbe.probe_database_url(
        cluster: cluster, database: sentinel_name, user: login[:user], password: login[:password]
      )
      child = VisibilityMigrationPrivilegeProbe.child_env(
        base_env: ENV.to_h.merge('DATABASE_URL' => sentinel_url, 'PRIMARY_DATABASE_URL' => sentinel_url),
        cluster: cluster,
        db_name: probe.schema_db_name,
        user: probe.role_name,
        password: password
      )
      %w[DATABASE_URL PRIMARY_DATABASE_URL].each do |key|
        database = ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver.new(child.fetch(key)).to_hash[:database]
        expect(database).to eq probe.database_name
      end

      refused_out, refused_status = run_schema_child(child.merge('E2_PRIVILEGE_EXPECT_DATABASE' => sentinel_name))
      expect(refused_status).not_to be_success, refused_out
      expect(refused_out).to include(VisibilityMigrationPrivilegeProbe::REFUSAL)
      expect(sentinel_count(sentinel_name)).to eq 1
      expect(probe_schema_loaded?(probe, password)).to be false

      load_out, load_status = run_schema_child(child)
      expect(load_status).to be_success, load_out
      expect(sentinel_count(sentinel_name)).to eq 1

      owner = PG.connect(
        VisibilityMigrationPrivilegeProbe.connect_options(
          cluster: cluster, dbname: probe.database_name, user: probe.role_name, password: password
        )
      )
      clients << owner
      flags = owner.exec(<<~SQL).first
        SELECT current_user, rolsuper, rolcreatedb, rolcreaterole
        FROM pg_roles WHERE rolname = current_user
      SQL
      expect(flags['current_user']).to eq probe.role_name
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

      with_owner_connection(probe, password) do |connection|
        expect(connection.select_value('SELECT current_user')).to eq probe.role_name
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

        holder = PG.connect(
          VisibilityMigrationPrivilegeProbe.connect_options(
            cluster: cluster, dbname: probe.database_name, user: probe.role_name, password: password
          )
        )
        clients << holder
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

      report = VisibilityMigrationPrivilegeProbe.write_report(
        directory: ENV.fetch('E2_PRIVILEGE_REPORT_DIR', nil),
        body: <<~REPORT
          server_version=#{admin_row['version']}
          admin_role=#{admin_row['role']} rolsuper=#{admin_row['rolsuper']} rolcreatedb=#{admin_row['rolcreatedb']} rolcreaterole=#{admin_row['rolcreaterole']}
          schema_role=#{probe.role_name} rolsuper=false rolcreatedb=false parameter_acl=0
          schema_load=success migration=E1-down E2-up follow-up-up E1-down E2-up follow-up-down
          canonical_200_to_201=1
        REPORT
      )
      written = File.read(report)
      expect(written).to include('schema_load=success')
      expect(written).to include('canonical_200_to_201=1')
      expect(written).not_to include(password)
      expect(written).not_to include(admin_password) if admin_password.present?
    rescue StandardError => e
      secrets = [password, admin_password]
      secrets.concat(child.values.grep(%r{://})) if child
      raise VisibilityMigrationPrivilegeProbe.redact_error(e, *secrets.compact)
    ensure
      close_clients(clients)
      admin&.close
      ActiveRecord::Base.establish_connection(:test)
      begin
        drop_probe(probe)
      ensure
        drop_sentinel!(sentinel_name)
      end
    end
  end

  def with_owner_connection(probe, password)
    ActiveRecord::Base.establish_connection(
      VisibilityMigrationPrivilegeProbe.ar_config(
        cluster: cluster, database: probe.database_name, user: probe.role_name, password: password
      )
    )
    yield ActiveRecord::Base.connection
  ensure
    ActiveRecord::Base.establish_connection(:test)
  end
end
# rubocop:enable Metrics/BlockLength
