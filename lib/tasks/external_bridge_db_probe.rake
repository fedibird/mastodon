# frozen_string_literal: true

# Hint only. It takes no lock and prints no credential.
#
# The authoritative check is the pooler, run by someone who already has its
# admin console: `SHOW CONFIG;` and `SHOW DATABASES;`, and read `pool_mode`.
# Session advisory locks are safe in session pooling and unsafe in transaction
# pooling (https://www.pgbouncer.org/features.html). This rake task is not a
# substitute, and a passing hint is not proof under load.
#
#   RAILS_ENV=production bundle exec rake external_bridge:db_session_probe
#
# Run it with the same DB_HOST, DB_PORT, and DATABASE_URL as Sidekiq. It asks
# two client connections for pg_backend_pid several times. A direct connection
# or session pooling keeps one backend per client, so the two pids stay
# distinct. Transaction pooling hands a backend out per statement, so a pid
# changes or both clients report the same one. PREPARED_STATEMENTS does not
# answer this.
#
# Nothing here is required by the E4 wrapper removal. That exclusion is a lease
# on a row. RSS::RefreshSource still takes a session advisory lock per source;
# that predates the asynchronous unsubscribe.
namespace :external_bridge do
  desc 'Hints whether this database route keeps a session per client. Does not take a lock. Prefer the pooler SHOW CONFIG.'
  task db_session_probe: :environment do
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    puts 'authoritative check: pooler admin console, SHOW CONFIG and SHOW DATABASES, column pool_mode'
    puts "route: host=#{config[:host].presence || '(socket)'} port=#{config[:port].presence || '(default)'}"

    pool = ActiveRecord::Base.connection_pool
    first = pool.checkout
    second = pool.checkout
    begin
      first_pids = Array.new(8) { first.select_value('SELECT pg_backend_pid()').to_i }
      second_pids = Array.new(8) { second.select_value('SELECT pg_backend_pid()').to_i }
      puts "backend pids, client A: #{first_pids.uniq.join(', ')}"
      puts "backend pids, client B: #{second_pids.uniq.join(', ')}"
      stable = first_pids.uniq.size == 1 && second_pids.uniq.size == 1 && first_pids.first != second_pids.first
      if stable
        puts 'hint: session semantics on this sample (direct or session pooling). Not proof under load.'
      else
        puts 'hint: NOT session-safe on this sample (transaction or statement pooling, or one shared backend).'
      end
      exit(stable ? 0 : 1)
    ensure
      pool.checkin(first) if first
      pool.checkin(second) if second
    end
  end
end
