# frozen_string_literal: true

module ExternalBridge
  module Streaming
    # Runs a block when the transaction that received it commits.
    #
    # Rails 6.1 moves the record onto a joinable parent when a savepoint
    # commits, and calls rolledback! if that parent rolls back. Releasing
    # the savepoint does not run the block. A top-level transaction commits
    # against NullTransaction, which is not joinable, so the block runs only
    # after that COMMIT.
    #
    # The test fixture transaction is also not joinable. An application
    # transaction opened inside an example therefore runs the block when it
    # commits, while the fixture transaction is still open. That is the same
    # rule as after_commit. The block is not parked on the fixture, because
    # the fixture never commits.
    class AfterOuterCommit
      def self.run(&block)
        connection = ApplicationRecord.connection
        if connection.open_transactions.zero?
          yield
          return
        end

        connection.add_transaction_record(Callback.new(block))
      end

      # Registered on the current transaction. Rails moves it to the parent
      # when a joinable savepoint commits without running callbacks.
      class Callback
        def initialize(block)
          @block = block
          @done = false
        end

        def before_committed!; end

        def committed!(should_run_callbacks: true)
          return unless should_run_callbacks
          return if @done

          @done = true
          @block.call
        end

        # Rails 6.1 always passes these keywords. Rollback never runs the block.
        def rolledback!(force_restore_state: false, should_run_callbacks: true) # rubocop:disable Lint/UnusedMethodArgument
          @done = true
        end

        def trigger_transactional_callbacks?
          true
        end
      end
    end
  end
end
