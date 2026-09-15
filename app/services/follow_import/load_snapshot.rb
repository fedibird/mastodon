# frozen_string_literal: true

# Read-only Sidekiq load snapshot, following the queue size/latency and
# ProcessSet concurrency checks used by Scheduler::AccountsStatusesCleanupScheduler.
# Failures are captured as error_class facts; they never raise to the caller.
module FollowImport
  class LoadSnapshot
    QUEUES = %w(default push pull).freeze

    def self.capture
      new.capture
    end

    def capture
      snapshot = { 'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION, 'queues' => {} }

      QUEUES.each do |name|
        snapshot['queues'][name] = queue_stats(name)
      rescue StandardError => e
        snapshot['queues'][name] = { 'error_class' => e.class.name }
      end

      begin
        snapshot['retry_size'] = Sidekiq::Stats.new.retry_size
      rescue StandardError => e
        snapshot['retry_size_error_class'] = e.class.name
      end

      begin
        processes = Sidekiq::ProcessSet.new.to_a
        snapshot['push_concurrency'] = concurrency_for(processes, 'push')
        snapshot['pull_concurrency'] = concurrency_for(processes, 'pull')
      rescue StandardError => e
        snapshot['concurrency_error_class'] = e.class.name
      end

      snapshot
    rescue StandardError => e
      { 'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION, 'error_class' => e.class.name }
    end

    private

    def queue_stats(name)
      queue = Sidekiq::Queue.new(name)
      { 'size' => queue.size, 'latency' => queue.latency }
    end

    def concurrency_for(processes, queue_name)
      processes.sum { |process| process['queues']&.include?(queue_name) ? process['concurrency'].to_i : 0 }
    end
  end
end
