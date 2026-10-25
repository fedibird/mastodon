# frozen_string_literal: true

# Reads nothing secret and prints no credential: only the configured host and
# port, a verdict, and the process ids PostgreSQL reports.
#
#   RAILS_ENV=production bundle exec rake external_bridge:db_session_probe
#
# Run it with the same environment (DB_HOST, DB_PORT, DATABASE_URL) as the
# Sidekiq process. The question it answers: do two client connections of this
# process end up on two PostgreSQL sessions that keep their own state? That is
# true for a direct connection and for PgBouncer in session pooling mode, and
# false for PgBouncer in transaction (or statement) pooling mode, where session
# advisory locks, SET without LOCAL, and temporary tables are not safe.
#
# The probe takes a session advisory lock on a random key on one connection and
# asks for the same key on a second connection. A second grant means both
# clients were served by one backend. It then releases what it took. A lock
# that cannot be released on the same backend stays on that backend under a
# random key nobody else asks for, until PgBouncer recycles the backend.
#
# It is evidence from this route, not a replacement for reading the PgBouncer
# `pool_mode` (`SHOW CONFIG;` or `SHOW DATABASES;` on its admin console, which a
# DBA runs; the console credentials are not needed here).
#
# The E4 wrapper removal (ExternalBridge::LinkWrapperRemovalWorker) does not
# depend on this: its exclusion is a lease on a row, one conditional UPDATE per
# step. RSS::RefreshSource still takes a session advisory lock per source; that
# code predates the asynchronous unsubscribe and is not changed here.
namespace :external_bridge do
  desc 'Reports whether this process gets session-level PostgreSQL semantics (direct or session pooling) or not (transaction pooling)'
  task db_session_probe: :environment do
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    puts "route: host=#{config[:host].presence || '(socket)'} port=#{config[:port].presence || '(default)'}"

    pool = ActiveRecord::Base.connection_pool
    first = pool.checkout
    second = pool.checkout
    key = SecureRandom.random_number(2**62)
    begin
      granted_first = first.select_value("SELECT pg_try_advisory_lock(#{key})")
      granted_second = second.select_value("SELECT pg_try_advisory_lock(#{key})")
      pids = Array.new(6) { [first.select_value('SELECT pg_backend_pid()'), second.select_value('SELECT pg_backend_pid()')] }.flatten.uniq
      shared_backend = [true, 't'].include?(granted_first) && [true, 't'].include?(granted_second)

      puts "backend pids seen by two clients over 12 statements: #{pids.join(', ')}"
      if shared_backend
        puts 'verdict: NOT session-safe. Two client connections were served by one PostgreSQL session (transaction or statement pooling).'
      else
        puts 'verdict: session semantics held for this probe (direct connection or session pooling).'
        puts 'note: one probe cannot prove it under load; read the pooler pool_mode as well.'
      end
      exit(shared_backend ? 1 : 0)
    ensure
      [first, second].each do |connection|
        3.times { break unless [true, 't'].include?(connection.select_value("SELECT pg_advisory_unlock(#{key})")) }
        pool.checkin(connection)
      end
    end
  end
end
