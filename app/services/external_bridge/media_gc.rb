# frozen_string_literal: true

module ExternalBridge
  # Releases files named by external_media_gc_intents. See MediaGc::Plan for
  # what may be named, and docs/external_rss_media_gc.md for the operator view.
  #
  # A job never carries status ids. drain! reads a bounded batch from the
  # table. The happy path releases the batch that just committed; a dead
  # process leaves the rows, and the scheduler calls drain! after the grace
  # period. Feature flags are not consulted: a plan that was committed has
  # to finish, and this class does not download or enable anything.
  class MediaGc
    BATCH = 25
    MAX_ATTEMPTS = 8
    LEASE = 5.minutes
    RETENTION = 7.days
    BACKOFF = [1.minute, 5.minutes, 15.minutes, 1.hour, 6.hours].freeze

    def self.grace
      ENV.fetch('EXTERNAL_MEDIA_GC_GRACE_SECONDS', '60').to_i.clamp(0, 3_600).seconds
    end

    def self.plan_purge!(media, deletion_id: nil)
      Plan.purge!(media, deletion_id: deletion_id)
    end

    def self.plan_replacement!(attachment_ids:, asset_ids:)
      Plan.replacement!(attachment_ids: attachment_ids, asset_ids: asset_ids)
    end

    # P3-A calls this after every projection has moved to a replacement asset.
    # A referenced asset is planned and then retained, not deleted.
    def self.plan_generation!(asset_id)
      Plan.generation!(asset_id)
    end

    def self.schedule_release!(attachment_ids:, asset_ids:)
      ids = normalize_ids(attachment_ids)
      assets = normalize_ids(asset_ids)
      return if ids.empty? && assets.empty?

      ActiveRecord::Base.connection.add_transaction_record(CommitHook.new(ids, assets))
    end

    def self.release_ids!(attachment_ids:, asset_ids:)
      Release.ids!(attachment_ids: attachment_ids, asset_ids: asset_ids)
    end

    def self.drain!(limit: BATCH, respect_grace: true)
      Release.drain!(limit: limit, respect_grace: respect_grace)
    end

    def self.diagnose(sample: 20)
      Report.diagnose(sample: sample)
    end

    def self.prune_resolved!(limit: 500)
      Report.prune_resolved!(limit: limit)
    end

    def self.requeue_failed!(limit: 100)
      Report.requeue_failed!(limit: limit)
    end

    def self.kick!
      return unless ExternalMediaGcIntent.pending.exists?

      RSS::MediaGcWorker.perform_in(grace)
    rescue StandardError => e
      Rails.logger.warn("[ExternalBridge::MediaGc] step=kick error=#{e.class}")
    end

    def self.normalize_ids(ids)
      Array(ids).map(&:to_i).uniq.reject(&:zero?)
    end
  end
end
