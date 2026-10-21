# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'External visibility migration follow-up' do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: "follow#{SecureRandom.hex(4)}")) }

  before do
    Setting.external_bridge_external_visibility = false
  end

  def run_migration(**options)
    ExternalBridge::VisibilityMigration::Runner.call(options)
  end

  def write_checkpoint(path, pending:, user_id: user.id)
    identity = ExternalBridge::VisibilityMigration::Checkpoint.identity
    payload = {
      'version' => 1,
      'database' => identity['database'],
      'instance' => identity['instance'],
      'scope' => { 'user_id' => user_id, 'subscription_id' => nil },
      'direction' => 'personal_to_external',
      'high_watermark_marker_id' => 50,
      'last_completed_marker_id' => 0,
      'pending_batch' => pending,
    }
    File.write(path, JSON.generate(payload))
    File.chmod(0o600, path)
  end

  describe 'search follow-up' do
    # The suite pushes :bypass. These examples put :custom_sidekiq on top so a
    # regression back to strategy.current.update cannot hide behind bypass or urgent.
    around do |example|
      Chewy.strategy(:custom_sidekiq) { example.run }
    end

    let(:legacy) { project_for(user, body: 'Search follow body') }
    let(:ordinary) { PostStatusService.new.call(user.account, text: 'Ordinary personal note', visibility: 'personal') }

    before do
      legacy
      ordinary
    end

    it 'does not ask the sidekiq strategy to update, and treats document not-found as success' do
      allow(Chewy).to receive(:enabled?).and_return(true)
      expect(Chewy.root_strategy).to eq :custom_sidekiq
      expect(Chewy.strategy.current).not_to receive(:update)
      expect(Chewy.client).to receive(:bulk).with(hash_including(refresh: true)).and_return(
        'items' => [{ 'delete' => { 'status' => 404, 'result' => 'not_found' } }]
      )
      expect(Chewy.client).to receive(:get) do |*args, **kwargs|
        raise absent_search_error(search_call_id(*args, **kwargs))
      end

      expect { ExternalBridge::VisibilityMigration::CacheSync.invalidate!([legacy[:status].id]) }.not_to raise_error
    end

    it 'refuses a bulk item that is neither deleted nor not-found' do
      second = project_for(user, body: 'Second search body')
      allow(Chewy).to receive(:enabled?).and_return(true)
      expect(Chewy.client).to receive(:bulk).and_return(
        'items' => [
          { 'delete' => { 'status' => 200, 'result' => 'deleted' } },
          { 'delete' => { 'status' => 429, 'error' => { 'type' => 'es_rejected_execution_exception' } } },
        ]
      )
      expect(Chewy.client).not_to receive(:get)

      expect do
        ExternalBridge::VisibilityMigration::CacheSync.invalidate!([legacy[:status].id, second[:status].id])
      end.to raise_error(ExternalBridge::VisibilityMigration::CacheSync::SearchFollowUpError, /did not complete/)
    end

    it 'does not delete an ordinary status document' do
      allow(Chewy).to receive(:enabled?).and_return(true)
      expect(Chewy.client).not_to receive(:bulk)

      expect do
        ExternalBridge::VisibilityMigration::CacheSync.invalidate!([ordinary.id])
      end.to raise_error(ExternalBridge::VisibilityMigration::CacheSync::SearchFollowUpError, /non-projection status #{ordinary.id}/)
    end

    it 'keeps the pending batch when search delete fails and removes the document on resume' do
      Setting.external_bridge_external_visibility = true
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      calls = 0
      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(Chewy.strategy.current).to receive(:update).and_raise('strategy update must not run')
      allow(Chewy.client).to receive(:bulk) do
        calls += 1
        raise 'es down' if calls == 1

        { 'items' => [{ 'delete' => { 'status' => 404, 'result' => 'not_found' } }] }
      end
      allow(Chewy.client).to receive(:get) do |*args, **kwargs|
        raise absent_search_error(search_call_id(*args, **kwargs))
      end

      expect do
        run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 10, batch_size: 10)
      end.to raise_error(ExternalBridge::VisibilityMigration::Runner::CacheIncomplete)

      expect(legacy[:status].reload.visibility).to eq 'external'
      expect(JSON.parse(File.read(path))['pending_batch']).to be_present
      expect(JSON.parse(File.read(path))['last_completed_marker_id']).to eq 0

      result = run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 10, batch_size: 10)
      expect(result.outcome).to eq :window_complete
      expect(result.exit_code).to eq 0
      expect(JSON.parse(File.read(path))['pending_batch']).to be_nil
      expect(calls).to eq 2
      expect(ordinary.reload.visibility).to eq 'personal'
    end

    it 'deletes a planted document under the custom sidekiq strategy before the checkpoint completes' do
      skip 'Elasticsearch is not reachable. This skip is not a pass.' unless elasticsearch_available?
      expect(Chewy.root_strategy).to eq :custom_sidekiq
      plant_document(legacy[:status])
      plant_document(ordinary)
      expect(indexed_document(legacy[:status].id)).to include('_id' => legacy[:status].id.to_s)
      expect(Chewy.strategy.current).not_to receive(:update)

      Setting.external_bridge_external_visibility = true
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      result = run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 10, batch_size: 10)

      expect(result.outcome).to eq :window_complete
      expect(indexed_document(legacy[:status].id)).to be_nil
      expect(indexed_document(ordinary.id)).to include('_id' => ordinary.id.to_s)
      expect(JSON.parse(File.read(path))['pending_batch']).to be_nil
    end

    it 'rejects an index-level bulk error and a not_found type that is not this document' do
      allow(Chewy).to receive(:enabled?).and_return(true)
      expect(Chewy.client).not_to receive(:get)
      expect(Chewy.client).to receive(:bulk).and_raise(index_missing_error)

      expect do
        ExternalBridge::VisibilityMigration::CacheSync.invalidate!([legacy[:status].id])
      end.to raise_error(ExternalBridge::VisibilityMigration::CacheSync::SearchFollowUpError, /search delete failed/)

      expect(Chewy.client).to receive(:bulk).and_return(
        'items' => [{
          'delete' => {
            'status' => 404,
            'result' => 'not_found',
            'error' => { 'type' => 'index_not_found_exception' },
          },
        }]
      )
      expect do
        ExternalBridge::VisibilityMigration::CacheSync.invalidate!([legacy[:status].id])
      end.to raise_error(ExternalBridge::VisibilityMigration::CacheSync::SearchFollowUpError, /did not complete/)
    end

    it 'accepts document_missing_exception and rejects a proxy 404 or a different id' do
      allow(Chewy).to receive(:enabled?).and_return(true)
      expect(Chewy.client).to receive(:bulk).and_return(
        'items' => [{
          'delete' => {
            'status' => 404,
            'result' => 'not_found',
            'error' => { 'type' => 'document_missing_exception' },
          },
        }]
      )
      expect(Chewy.client).to receive(:get).and_raise(proxy_not_found_error)
      expect do
        ExternalBridge::VisibilityMigration::CacheSync.invalidate!([legacy[:status].id])
      end.to raise_error(ExternalBridge::VisibilityMigration::CacheSync::SearchFollowUpError, /absence was not confirmed/)

      expect(Chewy.client).to receive(:bulk).and_return(
        'items' => [{ 'delete' => { 'status' => 200, 'result' => 'deleted' } }]
      )
      expect(Chewy.client).to receive(:get).and_raise(absent_search_error(legacy[:status].id + 1))
      expect do
        ExternalBridge::VisibilityMigration::CacheSync.invalidate!([legacy[:status].id])
      end.to raise_error(ExternalBridge::VisibilityMigration::CacheSync::SearchFollowUpError, /absence was not confirmed/)

      expect(Chewy.client).to receive(:bulk).and_return(
        'items' => [{
          'delete' => {
            'status' => 404,
            'result' => 'not_found',
            'error' => { 'type' => 'document_missing_exception' },
          },
        }]
      )
      expect(Chewy.client).to receive(:get).and_raise(absent_search_error(legacy[:status].id))
      expect do
        ExternalBridge::VisibilityMigration::CacheSync.invalidate!([legacy[:status].id])
      end.not_to raise_error
    end

    it 'keeps 201 and the pending batch when the index is missing, then finishes on the same checkpoint' do
      Setting.external_bridge_external_visibility = true
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      attempts = 0
      gets = 0
      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(Chewy.client).to receive(:bulk) do
        attempts += 1
        raise index_missing_error if attempts == 1

        { 'items' => [{ 'delete' => { 'status' => 404, 'result' => 'not_found' } }] }
      end
      allow(Chewy.client).to receive(:get) do |*args, **kwargs|
        gets += 1
        raise absent_search_error(search_call_id(*args, **kwargs))
      end

      expect do
        invoke_visibility_cli(apply: true, confirm_readers_ready: true, user_id: user.id.to_s, checkpoint: path, limit: '10', batch_size: '10')
      end.to raise_error(SystemExit) { |error| expect(error.status).to eq 6 }

      expect(gets).to eq 0
      expect(legacy[:status].reload.visibility).to eq 'external'
      expect(JSON.parse(File.read(path))['pending_batch']).to be_present
      expect(JSON.parse(File.read(path))['last_completed_marker_id']).to eq 0

      output = invoke_visibility_cli(apply: true, confirm_readers_ready: true, user_id: user.id.to_s, checkpoint: path, limit: '10', batch_size: '10')
      expect(output).to include('Apply finished this checkpoint window')
      expect(JSON.parse(File.read(path))['pending_batch']).to be_nil
      expect(gets).to eq 1
      expect(attempts).to eq 2
    end

    it 'keeps 201 and the pending batch when the delete check is an HTML 404, then finishes on the same checkpoint' do
      Setting.external_bridge_external_visibility = true
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      phase = :broken
      allow(Chewy).to receive(:enabled?).and_return(true)
      allow(Chewy.client).to receive(:bulk).and_return(
        'items' => [{ 'delete' => { 'status' => 200, 'result' => 'deleted' } }]
      )
      allow(Chewy.client).to receive(:get) do |*args, **kwargs|
        raise proxy_not_found_error if phase == :broken

        raise absent_search_error(search_call_id(*args, **kwargs))
      end

      expect do
        invoke_visibility_cli(apply: true, confirm_readers_ready: true, user_id: user.id.to_s, checkpoint: path, limit: '10', batch_size: '10')
      end.to raise_error(SystemExit) { |error| expect(error.status).to eq 6 }

      expect(legacy[:status].reload.visibility).to eq 'external'
      expect(JSON.parse(File.read(path))['pending_batch']['status_ids']).to eq [legacy[:status].id]
      phase = :ready

      output = invoke_visibility_cli(apply: true, confirm_readers_ready: true, user_id: user.id.to_s, checkpoint: path, limit: '10', batch_size: '10')
      expect(output).to include('Apply finished this checkpoint window')
      expect(JSON.parse(File.read(path))['pending_batch']).to be_nil
    end

    it 'sends 100 ids as one bulk slice' do
      ids = migration_ids(100)
      Setting.external_bridge_external_visibility = true
      counts = count_search_follow_up

      result = run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: File.join(Dir.mktmpdir, 'checkpoint.json'), limit: 200, batch_size: 200)
      expect(result.outcome).to eq :window_complete
      expect(counts).to include(bulk: 1, get: 100, status_pluck: 1, marker_pluck: 1, slices: 1)
      expect(ids.length).to eq 100
    end

    it 'splits 101 ids into two slices and repeats a finished slice after a later slice fails' do
      ids = migration_ids(101)
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      counts = count_search_follow_up(fail_slice: 2)
      Setting.external_bridge_external_visibility = true

      expect do
        run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 200, batch_size: 200)
      end.to raise_error(ExternalBridge::VisibilityMigration::Runner::CacheIncomplete)

      expect(Status.where(id: ids).pluck(:visibility).uniq).to eq ['external']
      expect(JSON.parse(File.read(path))['pending_batch']['status_ids'].length).to eq 101
      expect(JSON.parse(File.read(path))['last_completed_marker_id']).to eq 0
      expect(counts).to include(bulk: 2, get: 100, status_pluck: 2, marker_pluck: 2, slices: 2)

      counts[:fail_slice] = nil
      result = run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 200, batch_size: 200)
      expect(result.outcome).to eq :window_complete
      expect(JSON.parse(File.read(path))['pending_batch']).to be_nil
      expect(counts).to include(bulk: 4, get: 201, status_pluck: 4, marker_pluck: 4)
      expect(ordinary.reload.visibility).to eq 'personal'
    end
  end

  describe 'checkpoint lease' do
    self.use_transactional_tests = false

    after do
      next unless user&.persisted?

      account = user.account
      user.delete
      account&.delete
    end
    it 'refuses a second object in this process and leaves the file unchanged' do
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      scope = { 'user_id' => user.id, 'subscription_id' => nil }
      holder = ExternalBridge::VisibilityMigration::Checkpoint.new(path)
      holder.lease!
      holder.create!(scope, 4)
      holder.mark_pending!(marker_ids: [4], status_ids: [8], first_marker_id: 4, last_marker_id: 4)
      original = File.read(path)

      other = ExternalBridge::VisibilityMigration::Checkpoint.new(path)
      expect { other.lease! }.to raise_error(ExternalBridge::VisibilityMigration::Refusal) { |error| expect(error.code).to eq :checkpoint_busy }
      expect { other.create!({ 'user_id' => user.id + 1, 'subscription_id' => nil }, 9) }.to raise_error(ExternalBridge::VisibilityMigration::Refusal)
      expect { other.load!(scope) }.to raise_error(ExternalBridge::VisibilityMigration::Refusal) { |error| expect(error.code).to eq :checkpoint_busy }
      expect(File.read(path)).to eq original
    ensure
      holder&.release!
    end

    it 'refuses another process that lost the create race and resumes after that process dies' do
      dir = Dir.mktmpdir
      path = File.join(dir, 'checkpoint.json')
      scope = { 'user_id' => user.id, 'subscription_id' => nil }
      other_scope = { 'user_id' => user.id + 9, 'subscription_id' => nil }
      release = File.join(dir, 'release')
      ActiveRecord::Base.connection_pool.disconnect!
      winner, winner_ready = fork_checkpoint(path, scope, File.join(dir, 'winner.txt'), hold_until: release)
      read_handshake(winner_ready)
      loser, loser_ready = fork_checkpoint(path, other_scope, File.join(dir, 'loser.txt'))
      read_handshake(loser_ready)
      File.write(release, '1')
      Process.wait(winner)
      Process.wait(loser)
      ActiveRecord::Base.establish_connection

      results = [File.read(File.join(dir, 'winner.txt')), File.read(File.join(dir, 'loser.txt'))]
      expect(results).to contain_exactly('created', 'checkpoint_busy')
      stored = JSON.parse(File.read(path))
      expect([scope, other_scope]).to include(stored['scope'])
      expect(stored['pending_batch']).to be_nil
      original = File.read(path)

      resumed = nil
      held = File.join(dir, 'held.txt')
      pid = fork_and_hold(path, held)
      wait_for(held)
      busy = ExternalBridge::VisibilityMigration::Checkpoint.new(path)
      expect { busy.lease! }.to raise_error(ExternalBridge::VisibilityMigration::Refusal) { |error| expect(error.code).to eq :checkpoint_busy }
      expect(File.read(path)).to eq original
      Process.kill('KILL', pid)
      Process.wait(pid)

      resumed = ExternalBridge::VisibilityMigration::Checkpoint.new(path)
      resumed.lease!
      resumed.load!(stored['scope'])
      expect(resumed.pending_batch).to be_nil
      expect(resumed.watermark).to eq stored['high_watermark_marker_id']
    ensure
      resumed&.release!
      ActiveRecord::Base.establish_connection if ActiveRecord::Base.connection_pool.connections.empty?
    end
  end

  describe 'pending budget and verify limit' do
    it 'refuses a pending batch larger than this run before it locks or converts' do
      legacy = project_for(user, body: 'Budget body')
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      write_checkpoint(
        path,
        pending: {
          'marker_ids' => [11, 12, 13],
          'status_ids' => [21, 22, 23],
          'first_marker_id' => 11,
          'last_marker_id' => 13,
        }
      )
      original = File.read(path)
      Setting.external_bridge_external_visibility = true

      expect do
        run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: path, limit: 2, batch_size: 2)
      end.to raise_error(ExternalBridge::VisibilityMigration::Refusal, /Raise both to at least 3/)

      expect(File.read(path)).to eq original
      expect(legacy[:status].reload.visibility).to eq 'personal'
    end

    it 'checks a stop request before replaying pending work' do
      legacy = project_for(user, body: 'Stop body')
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      write_checkpoint(
        path,
        pending: {
          'marker_ids' => [legacy[:marker].id],
          'status_ids' => [legacy[:status].id],
          'first_marker_id' => legacy[:marker].id,
          'last_marker_id' => legacy[:marker].id,
        }
      )
      Setting.external_bridge_external_visibility = true

      result = run_migration(
        apply: true,
        confirm_readers_ready: true,
        user_id: user.id,
        checkpoint: path,
        limit: 10,
        batch_size: 10,
        stop_check: -> { true }
      )
      expect(result.outcome).to eq :stopped
      expect(result.exit_code).to eq 3
      expect(legacy[:status].reload.visibility).to eq 'personal'
      expect(JSON.parse(File.read(path))['pending_batch']['marker_ids']).to eq [legacy[:marker].id]
    end

    it 'counts the confirmation read against the verify limit' do
      project_for(user, body: 'Verify body')
      Setting.external_bridge_external_visibility = true
      Dir.mktmpdir do |dir|
        run_migration(apply: true, confirm_readers_ready: true, user_id: user.id, checkpoint: File.join(dir, 'checkpoint.json'), limit: 10, batch_size: 10)
      end

      tight = run_migration(verify: true, user_id: user.id, limit: 1)
      expect(tight.outcome).to eq :limit_reached
      expect(tight.exit_code).to eq 2
      expect(tight.to_s).to include('both reads count')

      clean = run_migration(verify: true, user_id: user.id, limit: 2)
      expect(clean.outcome).to eq :scope_complete
      expect(clean.counts[:scanned]).to eq 2
      expect(clean.counts[:already_external]).to eq 1
    end

    it 'rejects a pending id list above the batch maximum' do
      path = File.join(Dir.mktmpdir, 'checkpoint.json')
      ids = (1..1001).to_a
      write_checkpoint(
        path,
        pending: {
          'marker_ids' => ids,
          'status_ids' => ids,
          'first_marker_id' => 1,
          'last_marker_id' => 1001,
        }
      )

      expect do
        run_migration(user_id: user.id, checkpoint: path)
      end.to raise_error(ExternalBridge::VisibilityMigration::Refusal) { |error| expect(error.code).to eq :checkpoint_shape }
    end
  end

  def fork_checkpoint(path, scope, result_path, hold_until: nil)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      code = nil
      begin
        ActiveRecord::Base.establish_connection
        ExternalBridge::VisibilityMigration::Checkpoint::LEASES.clear
        checkpoint = ExternalBridge::VisibilityMigration::Checkpoint.new(path)
        checkpoint.lease!
        checkpoint.create!(scope, 4)
        code = 'created'
      rescue ExternalBridge::VisibilityMigration::Refusal => e
        code = e.code.to_s
      rescue StandardError => e
        code = "#{e.class}: #{e.message}"
      end
      File.write(result_path, code)
      writer.write('1')
      writer.close
      hold_lease(hold_until) if hold_until && code == 'created'
      exit!
    end
    writer.close
    [pid, reader]
  end

  def hold_lease(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    sleep 0.02 until File.file?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def read_handshake(io)
    byte = io.read(1)
    io.close
    raise 'checkpoint child exited before the handshake' if byte.blank?
  end

  def fork_and_hold(path, ready_path)
    fork do
      ActiveRecord::Base.establish_connection
      ExternalBridge::VisibilityMigration::Checkpoint::LEASES.clear
      checkpoint = ExternalBridge::VisibilityMigration::Checkpoint.new(path)
      checkpoint.lease!
      File.write(ready_path, 'held')
      sleep 30
      exit!
    end
  end

  def wait_for(path)
    50.times do
      return if File.file?(path)

      sleep 0.05
    end
    raise "timed out waiting for #{path}"
  end

  def elasticsearch_available?
    return false unless Chewy.enabled?

    Chewy.client.cluster.health
    true
  rescue StandardError
    false
  end

  def plant_document(status)
    Chewy.client.index(
      index: StatusesIndex.index_name,
      id: status.id.to_s,
      refresh: true,
      body: { 'id' => status.id, 'text' => 'planted' }
    )
  end

  def indexed_document(id)
    Chewy.client.indices.refresh(index: StatusesIndex.index_name)
    Chewy.client.get(index: StatusesIndex.index_name, id: id.to_s)
  rescue Elasticsearch::Transport::Transport::Errors::NotFound => e
    body = json_search_body(e.message)
    return nil if body && body['found'] == false && body['_id'].to_s == id.to_s && body['error'].nil?

    raise
  end

  def migration_ids(count)
    (count - 1).times { project_for(user, body: 'Batch body') }
    ExternalStatusProjection.where(user_id: user.id).order(:id).pluck(:status_id)
  end

  def count_search_follow_up(fail_slice: nil)
    counts = { bulk: 0, get: 0, status_pluck: 0, marker_pluck: 0, slices: 0, fail_slice: fail_slice }
    allow(Chewy).to receive(:enabled?).and_return(true)
    allow(ExternalBridge::VisibilityMigration::CacheSync).to receive(:invalidate!).and_wrap_original do |method, ids|
      counts[:slices] += 1
      method.call(ids)
    end
    allow(Chewy.client).to receive(:bulk) do |*args, **kwargs|
      counts[:bulk] += 1
      payload = search_payload(*args, **kwargs)
      ids = Array(payload[:body] || payload['body']).map { |entry| entry.dig(:delete, :_id) || entry.dig('delete', '_id') }
      raise 'slice failed' if counts[:fail_slice] && counts[:bulk] == counts[:fail_slice]

      result = counts[:bulk] > 2 ? 'not_found' : 'deleted'
      status = result == 'deleted' ? 200 : 404
      { 'items' => ids.map { { 'delete' => { 'status' => status, 'result' => result } } } }
    end
    allow(Chewy.client).to receive(:get) do |*args, **kwargs|
      counts[:get] += 1
      raise absent_search_error(search_call_id(*args, **kwargs))
    end
    allow(Status).to receive(:unscoped).and_wrap_original do |original, *args, **kwargs, &block|
      relation = original.call(*args, **kwargs, &block)
      next relation unless relation.is_a?(ActiveRecord::Relation)

      allow(relation).to receive(:where).and_wrap_original do |where, *where_args, **where_kwargs, &where_block|
        scoped = where.call(*where_args, **where_kwargs, &where_block)
        allow(scoped).to receive(:pluck).and_wrap_original do |pluck, *cols|
          counts[:status_pluck] += 1 if cols == %i(id visibility external_projection)
          pluck.call(*cols)
        end
        scoped
      end
      relation
    end
    allow(ExternalStatusProjection).to receive(:where).and_wrap_original do |where, *args, **kwargs|
      scoped = kwargs.empty? ? where.call(*args) : where.call(*args, **kwargs)
      arguments = args.find { |value| value.is_a?(Hash) } || kwargs
      if arguments.key?(:status_id)
        allow(scoped).to receive(:pluck).and_wrap_original do |pluck, *cols|
          counts[:marker_pluck] += 1 if cols == %i(status_id)
          pluck.call(*cols)
        end
      end
      scoped
    end
    counts
  end

  def invoke_visibility_cli(options)
    require Rails.root.join('lib/mastodon/upgrade_cli')
    stdout = $stdout
    output = StringIO.new
    $stdout = output
    Mastodon::UpgradeCLI.new.invoke(:external_status_visibility, [], options)
    output.string
  ensure
    $stdout = stdout
  end

  def absent_search_error(id)
    body = { '_index' => 'statuses', '_id' => id.to_s, 'found' => false }.to_json
    Elasticsearch::Transport::Transport::Errors::NotFound.new("[404] #{body}")
  end

  def index_missing_error
    body = {
      'error' => { 'type' => 'index_not_found_exception', 'reason' => 'no such index [statuses]' },
      'status' => 404,
    }.to_json
    Elasticsearch::Transport::Transport::Errors::NotFound.new("[404] #{body}")
  end

  def proxy_not_found_error
    Elasticsearch::Transport::Transport::Errors::NotFound.new('[404] <html><title>404 Not Found</title></html>')
  end

  def search_call_id(*args, **kwargs)
    payload = search_payload(*args, **kwargs)
    payload[:id] || payload['id']
  end

  def search_payload(*args, **kwargs)
    payload = args.find { |value| value.is_a?(Hash) } || {}
    payload.merge(kwargs)
  end

  def json_search_body(message)
    JSON.parse(message.to_s.sub(/\A\[\d+\]\s*/, ''))
  rescue JSON::ParserError, TypeError
    nil
  end
end
# rubocop:enable Metrics/BlockLength
