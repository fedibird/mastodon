# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require_relative '../../script/feed_delivery_reason_rollout'

module FeedDeliveryReasonRolloutExamples
  def rollout_snapshot(time:, keys:, phase: 'shadow')
    {
      'schema' => FeedDeliveryReasonRollout::SCHEMA,
      'prefix' => FeedDeliveryReasonRollout::PREFIX,
      'phase' => phase,
      'captured_at' => time,
      'keys' => keys,
    }
  end
end

RSpec.describe 'feed delivery rollout deltas', type: :model do
  include FeedDeliveryReasonRolloutExamples

  let(:prefix) { FeedDeliveryReasonRollout::PREFIX }
  let(:first_key) { "#{prefix}:2026112314" }
  let(:second_key) { "#{prefix}:2026112315" }

  it 'subtracts hourly Redis hashes correctly across a UTC hour boundary' do
    before_keys = { first_key => { 'job|reason=keyword' => 20, 'kw|qual=reply|result=agree' => 4 } }
    after_keys = {
      first_key => { 'job|reason=keyword' => 25, 'kw|qual=reply|result=agree' => 7 },
      second_key => { 'job|reason=keyword' => 12, 'kw|qual=reply|result=agree' => 2 },
    }
    before = rollout_snapshot(time: '2026-11-23T14:55:00Z', keys: before_keys)
    after = rollout_snapshot(time: '2026-11-23T15:05:00Z', keys: after_keys)

    result = FeedDeliveryReasonRollout.compare(before, after)

    expect(result['summary']).to include('keyword_jobs' => 17, 'reply_agree' => 5)
    expect(result['gate']['status']).to eq 'REVIEW_REQUIRED'
    expect(result['duration_seconds']).to eq 600
  end

  it 'does not accept expired or reset counters as negative deltas' do
    before = rollout_snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => { 'job|reason=keyword' => 20 } })
    after = rollout_snapshot(time: '2026-11-23T14:05:00Z', keys: { first_key => { 'job|reason=keyword' => 5 } })

    expect { FeedDeliveryReasonRollout.compare(before, after) }.to raise_error(FeedDeliveryReasonRollout::Error, /negative counter/)
  end

  it 'includes both endpoint hours when an interval lasts exactly 72 hours' do
    start = Time.utc(2026, 11, 20, 0, 30, 0)
    finish = start + (FeedDeliveryReasonRollout::MAX_HOURS * 3600)
    keys = FeedDeliveryReasonRollout.hour_keys(start, finish)
    before_keys = { keys.first => { 'job|reason=keyword' => 8 } }
    after_keys = keys.to_h { |key| [key, {}] }
    after_keys[keys.first] = { 'job|reason=keyword' => 11 }
    after_keys[keys.last] = { 'job|reason=keyword' => 5 }
    before = rollout_snapshot(time: start.iso8601, keys: before_keys)
    after = rollout_snapshot(time: finish.iso8601, keys: after_keys)

    expect(keys.size).to eq FeedDeliveryReasonRollout::MAX_SNAPSHOT_HOURS
    expect(FeedDeliveryReasonRollout.compare(before, after)['summary']).to include('keyword_jobs' => 8)
    overtime = rollout_snapshot(time: (finish + 1).iso8601, keys: after_keys)
    expect { FeedDeliveryReasonRollout.compare(before, overtime) }.to raise_error(FeedDeliveryReasonRollout::Error, /72 hours/)
  end
end

RSpec.describe 'feed delivery rollout gates', type: :model do
  include FeedDeliveryReasonRolloutExamples

  let(:prefix) { FeedDeliveryReasonRollout::PREFIX }
  let(:first_key) { "#{prefix}:2026112314" }
  let(:second_key) { "#{prefix}:2026112315" }

  it 'blocks a shadow promotion when any disagreement or Redis persistence failure is observed' do
    before = rollout_snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} })
    counters = {
      'job|reason=keyword' => 100,
      'kw|qual=reply|result=agree' => 30,
      'kw|qual=ignore_block|result=disagree' => 1,
      'meta|result=persist_failure' => 1,
    }
    after = rollout_snapshot(time: '2026-11-23T14:10:00Z', keys: { first_key => counters })

    result = FeedDeliveryReasonRollout.compare(before, after)

    expect(result['gate']['status']).to eq 'BLOCKED'
    expect(result['gate']['reasons'].size).to eq 2
  end

  it 'reports insufficient sample sizes rather than declaring success' do
    before = rollout_snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} })
    after = rollout_snapshot(time: '2026-11-23T14:10:00Z', keys: { first_key => { 'job|reason=keyword' => 25 } })

    result = FeedDeliveryReasonRollout.compare(before, after, min_jobs: 100, min_compared: 10)

    expect(result['gate']['status']).to eq 'INSUFFICIENT'
    expect(result['gate']['reasons']).to include('keyword jobs < 100', 'reply comparison samples < 10')
  end

  it 'treats an unobserved shadow scenario as insufficient when a minimum was requested' do
    before = rollout_snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} })
    counters = { 'job|reason=keyword' => 100, 'kw|qual=reply|result=agree' => 10 }
    after = rollout_snapshot(time: '2026-11-23T14:10:00Z', keys: { first_key => counters })
    minima = { 'ignore_block_compared' => 1, 'list_compared' => 1 }

    result = FeedDeliveryReasonRollout.compare(before, after, min_jobs: 100, min_compared: 10, min_coverage: minima)

    expect(result['coverage']).to include('reply_compared' => 10, 'ignore_block_compared' => 0, 'list_compared' => 0)
    expect(result['gate']['status']).to eq 'INSUFFICIENT'
    expect(result['gate']['reasons']).to include('ignore_block_compared < 1 (observed 0)', 'list_compared < 1 (observed 0)')
  end

  it 'refuses to compare different phases or an hour outside snapshot coverage' do
    before = rollout_snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} })
    after = rollout_snapshot(time: '2026-11-23T15:00:00Z', keys: { first_key => {}, second_key => {} })

    expect { FeedDeliveryReasonRollout.compare(before, after.merge('phase' => 'enforce')) }
      .to raise_error(FeedDeliveryReasonRollout::Error, /different phases/)
    expect { FeedDeliveryReasonRollout.compare(before, after.merge('keys' => { second_key => {} })) }
      .to raise_error(FeedDeliveryReasonRollout::Error, /hour coverage/)
  end
end

RSpec.describe 'feed delivery rollout reports', type: :model do
  include FeedDeliveryReasonRolloutExamples

  let(:prefix) { FeedDeliveryReasonRollout::PREFIX }
  let(:first_key) { "#{prefix}:2026112314" }

  def write_pair(directory, after_counters, phase: 'shadow')
    before = rollout_snapshot(time: '2026-11-23T14:00:00Z', keys: { first_key => {} }, phase: phase)
    after = rollout_snapshot(time: '2026-11-23T14:10:00Z', keys: { first_key => after_counters }, phase: phase)
    before_path = File.join(directory, 'before.json')
    after_path = File.join(directory, 'after.json')
    File.write(before_path, JSON.generate(before))
    File.write(after_path, JSON.generate(after))
    [before_path, after_path]
  end

  it 'prints evidence counts separately from fallback' do
    Dir.mktmpdir do |directory|
      counters = { 'kw|qual=reply|result=evidence' => 4, 'kw|qual=reply|result=fallback' => 1 }
      before_path, after_path = write_pair(directory, counters)
      output = nil
      status = nil
      expect do
        output = capture_output { status = FeedDeliveryReasonRollout.run(['compare', '--before', before_path, '--after', after_path]) }
      end.not_to raise_error
      expect(status).to eq 0
      expect(output).to include('reply_evidence=4 reply_fallback=1 reply_evidence_share=0.800 (evidence/(evidence+fallback))')
      expect(output).to include('ignore_block_evidence=0 ignore_block_fallback=0')
      expect(output).to include('NOTE: counters can lag by one metrics flush')
    end
  end

  def capture_output
    stdout = StringIO.new
    original = $stdout
    $stdout = stdout
    yield
    stdout.string
  ensure
    $stdout = original
  end

  it 'returns the strict status when enforce evidence was not observed' do
    Dir.mktmpdir do |directory|
      before_path, after_path = write_pair(directory, { 'job|reason=keyword' => 100 }, phase: 'enforce')
      argv = ['compare', '--before', before_path, '--after', after_path, '--strict', '--min-coverage', 'reply_evidence=1']
      status = nil
      expect { status = FeedDeliveryReasonRollout.run(argv) }.to output(/INSUFFICIENT/).to_stdout
      expect(status).to eq 3
    end
  end

  it 'never overwrites a snapshot file' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'snapshot.json')
      FeedDeliveryReasonRollout.write_new_json(path, { 'a' => 1 })

      expect(File.stat(path).mode & 0o777).to eq 0o600
      expect { FeedDeliveryReasonRollout.write_new_json(path, { 'a' => 2 }) }
        .to raise_error(FeedDeliveryReasonRollout::Error, /will not overwrite/)
    end
  end
end

RSpec.describe 'feed delivery rollout hour coverage', type: :model do
  include FeedDeliveryReasonRolloutExamples

  it 'rejects a 72 hour interval whose later snapshot dropped the starting hour' do
    start = Time.utc(2026, 11, 20, 0, 0, 0)
    finish = start + (FeedDeliveryReasonRollout::MAX_HOURS * 3600)
    needed = FeedDeliveryReasonRollout.hour_keys(start, finish)
    covered = needed.drop(1)
    before = rollout_snapshot(time: start.iso8601, keys: { needed.first => {} })
    after = rollout_snapshot(time: finish.iso8601, keys: covered.to_h { |key| [key, {}] })

    expect(covered.size).to eq FeedDeliveryReasonRollout::MAX_HOURS
    expect { FeedDeliveryReasonRollout.compare(before, after) }.to raise_error(FeedDeliveryReasonRollout::Error, /hour coverage/)
  end
end

RSpec.describe 'feed delivery rollout process and database checks', type: :model do
  it 'reports a MainPID change and ignores files with no units' do
    start_text = "unit=mastodon-web.service main_pid=10 (extra)\n"
    changed = "unit=mastodon-web.service main_pid=11 (extra)\n"

    expect(FeedDeliveryReasonRollout.pid_changes(start_text, start_text)).to eq []
    expect(FeedDeliveryReasonRollout.pid_changes(start_text, changed)).to eq ['mastodon-web.service main_pid 10 -> 11']
    expect(FeedDeliveryReasonRollout.pid_changes('', '')).to eq []
  end

  it 'accepts only read-only statements from the baseline SQL' do
    sql = File.read(Rails.root.join('script/feed_delivery_reason_pg_baseline.sql'))

    expect(FeedDeliveryReasonRollout.select_statements(sql).size).to eq 3
    expect { FeedDeliveryReasonRollout.select_statements('DELETE FROM users') }
      .to raise_error(FeedDeliveryReasonRollout::Error, /read-only/)
  end

  it 'refuses a connection that is not the Rails database' do
    raw = Struct.new(:name) do
      def exec(_sql)
        self
      end

      def getvalue(_row, _column)
        name
      end
    end.new('other_database')

    expect { FeedDeliveryReasonRollout.assert_same_database!(raw, 'mastodon') }
      .to raise_error(FeedDeliveryReasonRollout::Error, /does not match/)
  end

  it 'writes a read-only baseline for the Rails database without a connection url' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'pg.txt')
      status = FeedDeliveryReasonRollout.pg_baseline_command(['--out', path])
      text = File.read(path)

      expect(status).to eq 0
      expect(text).to include(ActiveRecord::Base.connection_db_config.database)
      expect(text).not_to match(%r{postgres(?:ql)?://})
      expect(text).not_to include('password=')
    end
  end
end

RSpec.describe 'feed delivery rollout mode evidence', type: :model do
  def environ_with(assignment)
    "#{assignment}\0PATH=/usr/bin\0"
  end

  it 'reads an explicit initial value and does not call a blank or invalid value unknown' do
    expect(FeedDeliveryReasonRollout.classify_process_mode(environ_with('FEED_DELIVERY_REASON_MODE=Shadow'))).to include('mode' => 'shadow')
    expect(FeedDeliveryReasonRollout.classify_process_mode(environ_with('FEED_DELIVERY_REASON_MODE='))).to include('mode' => 'off')
    expect(FeedDeliveryReasonRollout.classify_process_mode(environ_with('FEED_DELIVERY_REASON_MODE=YES'))).to include('mode' => 'off')
    expect(FeedDeliveryReasonRollout.classify_process_mode("PATH=/usr/bin\0")).to include('mode' => 'unknown')
  end

  it 'reports the explicit mode of another process and ignores this process environment' do
    previous = ENV.fetch('FEED_DELIVERY_REASON_MODE', nil)
    ENV['FEED_DELIVERY_REASON_MODE'] = 'enforce'
    pid = Process.spawn({ 'FEED_DELIVERY_REASON_MODE' => 'shadow' }, 'sleep', '30')
    sleep 0.2
    stdout, _stderr, status = Open3.capture3(
      RbConfig.ruby,
      Rails.root.join('script/feed_delivery_reason_rollout.rb').to_s,
      'process-modes', '--pid', pid.to_s, '--expect', 'shadow'
    )

    expect(status.exitstatus).to eq 0
    expect(stdout).to include("pid=#{pid} FEED_DELIVERY_REASON_MODE=shadow")
    expect(stdout).not_to include('=enforce')
  ensure
    if previous.nil?
      ENV.delete('FEED_DELIVERY_REASON_MODE')
    else
      ENV['FEED_DELIVERY_REASON_MODE'] = previous
    end
    if pid
      Process.kill('TERM', pid)
      Process.wait(pid)
    end
  end
end

RSpec.describe 'feed delivery rollout effective mode limits', type: :model do
  it 'does not treat a mode that exists only after Dotenv.load as off or enforce' do
    pid = nil
    Dir.mktmpdir do |directory|
      env_file = File.join(directory, '.env')
      ready = File.join(directory, 'ready')
      File.write(env_file, "FEED_DELIVERY_REASON_MODE=enforce\n")
      pid = Process.spawn(
        { 'FEED_DELIVERY_REASON_MODE' => nil },
        'bundle', 'exec', 'ruby', '-e', <<~'RUBY', env_file, ready,
          require 'dotenv'
          Dotenv.load(ARGV[0])
          File.write(ARGV[1], ENV.fetch('FEED_DELIVERY_REASON_MODE', 'missing'))
          sleep 30
        RUBY
        chdir: Rails.root.to_s
      )
      loaded = nil
      30.times do
        loaded = File.read(ready) if File.exist?(ready)
        break if loaded
        sleep 0.1
      end
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        Rails.root.join('script/feed_delivery_reason_rollout.rb').to_s,
        'process-modes', '--pid', pid.to_s, '--expect', 'off'
      )

      expect(loaded).to eq 'enforce'
      expect(status.exitstatus).to eq 3
      expect(stdout).to include("pid=#{pid} FEED_DELIVERY_REASON_MODE=unknown")
      expect(stdout).not_to include('=off')
      expect(stdout).not_to include('=enforce')
      expect(stderr).to include('missing initial variable is not off')
    end
  ensure
    if pid
      Process.kill('TERM', pid)
      Process.wait(pid)
    end
  end
end

RSpec.describe 'feed delivery rollout pg-baseline arguments', type: :model do
  it 'exits 2 for a missing pg-baseline path before Rails is loaded' do
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      Rails.root.join('script/feed_delivery_reason_rollout.rb').to_s,
      'pg-baseline'
    )

    expect(status.exitstatus).to eq 2
    expect(stderr).to include('ERROR: --out PATH is required')
    expect(stderr).not_to include('uninitialized constant')
    expect(stdout).to eq ''
  end
end
