# frozen_string_literal: true

require 'rails_helper'

describe RefreshDirtyEmojiReactionCachesWorker do
  subject(:worker) { described_class.new }

  def dirty_stat(status, cache: '[]', count: 0)
    StatusStat.create!(status: status, emoji_reactions_cache: cache, emoji_reactions_count: count, emoji_reactions_cache_dirty: true)
  end

  it 'uses an until-executing lock so a follow-up enqueued during perform is kept' do
    expect(described_class.get_sidekiq_options['lock']).to eq :until_executing
  end

  it 'refreshes dirty statuses and leaves clean statuses alone' do
    dirty_status = Fabricate(:status)
    clean_status = Fabricate(:status)
    account = Fabricate(:account)
    EmojiReaction.create!(account: account, status: dirty_status, name: '👍')
    dirty_status.status_stat.update!(emoji_reactions_cache: '[]', emoji_reactions_count: 0, emoji_reactions_cache_dirty: true)
    StatusStat.create!(status: clean_status, emoji_reactions_cache: 'keep', emoji_reactions_count: 3, emoji_reactions_cache_dirty: false)

    worker.perform

    expect(dirty_status.status_stat.reload.emoji_reactions_count).to eq 1
    expect(dirty_status.status_stat.emoji_reactions_cache_dirty).to be false
    expect(clean_status.status_stat.reload.emoji_reactions_cache).to eq 'keep'
    expect(clean_status.status_stat.emoji_reactions_count).to eq 3
    expect(clean_status.status_stat.emoji_reactions_cache_dirty).to be false
  end

  it 'stops at the batch size and schedules the next batch while dirty rows remain' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    allow(described_class).to receive(:perform_async)
    first, second = [Fabricate(:status), Fabricate(:status)].sort_by(&:id)
    dirty_stat(first, cache: 'old')
    dirty_stat(second, cache: 'old')

    worker.perform

    expect(first.status_stat.reload.emoji_reactions_cache_dirty).to be false
    expect(second.status_stat.reload.emoji_reactions_cache_dirty).to be true
    expect(described_class).to have_received(:perform_async).with(first.id)
  end

  it 'schedules a follow-up when another status is invalidated during the batch' do
    target = Fabricate(:status)
    other = Fabricate(:status)
    dirty_stat(target)
    StatusStat.create!(status: other, emoji_reactions_cache: 'keep', emoji_reactions_count: 0, emoji_reactions_cache_dirty: false)
    allow(described_class).to receive(:perform_async)
    allow_any_instance_of(Status).to receive(:refresh_grouped_emoji_reactions_if_dirty!).and_wrap_original do |method, *args|
      EmojiReactionCacheInvalidator.mark_status!(other.id)
      method.call(*args)
    end

    worker.perform

    expect(other.status_stat.reload.emoji_reactions_cache_dirty).to be true
    expect(described_class).to have_received(:perform_async).at_least(:once)
  end

  it 'hands a failed status to the per-status worker without rescanning it immediately' do
    failing, healthy = [Fabricate(:status), Fabricate(:status)].sort_by(&:id)
    dirty_stat(failing, cache: 'stale', count: 2)
    dirty_stat(healthy, cache: 'old', count: 1)
    allow(RefreshEmojiReactionCacheWorker).to receive(:perform_async)
    allow(described_class).to receive(:perform_async)
    allow_any_instance_of(Status).to receive(:generate_grouped_emoji_reactions).and_wrap_original do |method, *args|
      raise StandardError, 'boom' if method.receiver.id == failing.id

      method.call(*args)
    end

    worker.perform

    expect(healthy.status_stat.reload.emoji_reactions_cache_dirty).to be false
    failing_stat = failing.status_stat.reload
    expect(failing_stat.emoji_reactions_cache_dirty).to be true
    expect(failing_stat.emoji_reactions_cache).to eq 'stale'
    expect(failing_stat.emoji_reactions_count).to eq 2
    expect(RefreshEmojiReactionCacheWorker).to have_received(:perform_async).with(failing.id)
    expect(described_class).not_to have_received(:perform_async)
  end

  describe 'dirty existence probes' do
    def capture_sql(&block)
      statements = []
      callback = lambda do |*_args, payload|
        binds = payload[:type_casted_binds]
        binds = binds.call if binds.respond_to?(:call)
        statements << { sql: payload[:sql].to_s, binds: Array(binds) }
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      statements
    end

    def probe_statement(statements)
      statements.find do |statement|
        statement[:sql].include?('SELECT "status_stats"."status_id"') &&
          statement[:sql].include?('emoji_reactions_cache_dirty') &&
          statement[:binds].last == 1
      end
    end

    def expect_ordered_probe(statement)
      expect(statement).not_to be_nil
      sql = statement[:sql]
      expect(sql).to include('SELECT "status_stats"."status_id"')
      expect(sql).to include('"status_stats"."emoji_reactions_cache_dirty" = $1')
      expect(sql).to include('ORDER BY "status_stats"."status_id" ASC')
      expect(sql).to match(/LIMIT \$\d+\z/)
      expect(statement[:binds].first).to eq true
      expect(statement[:binds].last).to eq 1
      expect(sql).not_to include('SELECT 1 AS one')
    end

    it 'is true when a dirty row exists and reads one ordered status_id' do
      status = Fabricate(:status)
      dirty_stat(status)

      statements = capture_sql { expect(worker.send(:dirty_exists?)).to be true }

      expect_ordered_probe(probe_statement(statements))
    end

    it 'is false when no dirty row exists' do
      status = Fabricate(:status)
      StatusStat.create!(status: status, emoji_reactions_cache: 'keep', emoji_reactions_count: 0, emoji_reactions_cache_dirty: false)

      statements = capture_sql { expect(worker.send(:dirty_exists?)).to be false }

      expect_ordered_probe(probe_statement(statements))
    end

    it 'is false when the only dirty rows are excluded failed ids' do
      failed = Fabricate(:status)
      dirty_stat(failed)

      statements = capture_sql { expect(worker.send(:dirty_exists_outside?, [failed.id])).to be false }
      statement = probe_statement(statements)

      expect_ordered_probe(statement)
      expect(statement[:sql]).to include('"status_stats"."status_id" != $2')
      expect(statement[:binds]).to include(failed.id)
    end

    it 'is true when a dirty row remains outside the failed ids' do
      failed_a, failed_b, other = [Fabricate(:status), Fabricate(:status), Fabricate(:status)].sort_by(&:id)
      dirty_stat(failed_a)
      dirty_stat(failed_b)
      dirty_stat(other)

      statements = capture_sql { expect(worker.send(:dirty_exists_outside?, [failed_a.id, failed_b.id])).to be true }
      statement = probe_statement(statements)

      expect_ordered_probe(statement)
      expect(statement[:sql]).to include('NOT IN')
      expect(statement[:binds]).to include(failed_a.id, failed_b.id)
      expect(statement[:binds]).not_to include(other.id)
    end

    it 'is false when every dirty row is in a multi-id exclusion' do
      failed_a, failed_b = [Fabricate(:status), Fabricate(:status)].sort_by(&:id)
      dirty_stat(failed_a)
      dirty_stat(failed_b)

      statements = capture_sql { expect(worker.send(:dirty_exists_outside?, [failed_a.id, failed_b.id])).to be false }
      statement = probe_statement(statements)

      expect_ordered_probe(statement)
      expect(statement[:sql]).to include('NOT IN')
      expect(statement[:binds]).to include(failed_a.id, failed_b.id)
    end

    it 'is true only for a dirty status_id after the cursor' do
      earlier, later = [Fabricate(:status), Fabricate(:status)].sort_by(&:id)
      dirty_stat(earlier)
      dirty_stat(later)

      missing = capture_sql { expect(worker.send(:dirty_exists_after?, later.id)).to be false }
      present = capture_sql { expect(worker.send(:dirty_exists_after?, earlier.id)).to be true }
      missing_probe = probe_statement(missing)
      present_probe = probe_statement(present)

      expect_ordered_probe(missing_probe)
      expect_ordered_probe(present_probe)
      expect(present_probe[:sql]).to include(%("status_stats"."status_id" > #{earlier.id}))
      expect(missing_probe[:sql]).to include(%("status_stats"."status_id" > #{later.id}))
    end
  end
end
