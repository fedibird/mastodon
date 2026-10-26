# frozen_string_literal: true

module ExternalBridge
  class MediaGc
    # Registered inside the transaction that wrote the intents. Rails runs
    # committed! only when that transaction (or the parent it bubbled to)
    # commits, and rolledback! when it does not. File deletion stays on the
    # committed! side, so a rolled-back purge still has its blobs.
    class CommitHook
      def initialize(attachment_ids, asset_ids)
        @attachment_ids = attachment_ids
        @asset_ids = asset_ids
      end

      def before_committed!; end

      def trigger_transactional_callbacks?
        true
      end

      def committed!(should_run_callbacks: true)
        return unless should_run_callbacks

        MediaGc.settle_rechecks!(@asset_ids)
        MediaGc.release_ids!(attachment_ids: @attachment_ids, asset_ids: @asset_ids)
      rescue StandardError => e
        Rails.logger.warn("[ExternalBridge::MediaGc] step=commit_hook error=#{e.class}")
      end

      def rolledback!(*)
        nil
      end
    end
  end
end
