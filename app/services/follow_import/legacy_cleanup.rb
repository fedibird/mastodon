# frozen_string_literal: true

require 'csv'

# Operator-only cleanup of leftover unmarked follow Imports (NULL pipeline
# version / provenance-unknown). Never used by the watchdog or ProcessImportWorker.
# Unknown non-NULL versions are not leftover and must not be deleted here.
#
# INCIDENT-SAFE ROLLOUT
#   1. Stop the old FollowImportCsvCleanupScheduler recovery pass before the
#      migration/code switch (that query has no version guard).
#   2. During a rolling deploy, pause Follow Import acceptance, or wait until
#      every web process writes the current marker and no unmarked jobs from
#      old web processes remain in Sidekiq, then switch Sidekiq/scheduler.
#   3. Do not run APPLY until every web / Sidekiq / scheduler process is on
#      this revision. Always dry-run first.
module FollowImport
  class LegacyCleanup
    REPORT_HEADERS = %w(import_id account_id username created_at overwrite data_file_name data_file_size).freeze

    Result = Struct.new(:before, :apply, :candidates, :destroyed_ids, :skipped_ids, :manifest_path, keyword_init: true)

    def initialize(before:, apply: false, manifest_path: nil)
      raise ArgumentError, 'BEFORE is required; refusing to scan without a cutoff' if before.blank?

      @before        = coerce_time(before)
      @apply         = apply
      @manifest_path = manifest_path.presence
    end

    def candidates
      @candidates ||= Import.legacy_follow_imports_before(@before).includes(:account).order(:created_at).to_a
    end

    def call
      write_manifest if @manifest_path
      destroyed_ids, skipped_ids = @apply ? destroy_candidates! : [[], []]

      Result.new(
        before: @before,
        apply: @apply,
        candidates: candidates,
        destroyed_ids: destroyed_ids,
        skipped_ids: skipped_ids,
        manifest_path: @manifest_path
      )
    end

    def row_for(import)
      {
        'import_id' => import.id,
        'account_id' => import.account_id,
        'username' => import.account&.username,
        'created_at' => import.created_at&.iso8601,
        'overwrite' => import.overwrite?,
        'data_file_name' => import.data_file_name,
        'data_file_size' => import.data_file_size,
      }
    end

    private

    def coerce_time(value)
      return value if value.is_a?(Time)

      parsed = Time.zone.parse(value.to_s)
      raise ArgumentError, "invalid BEFORE: #{value.inspect}" if parsed.nil?

      parsed
    end

    def write_manifest
      CSV.open(@manifest_path, 'w') do |csv|
        csv << REPORT_HEADERS
        candidates.each do |import|
          csv << REPORT_HEADERS.map { |key| row_for(import)[key] }
        end
      end
    end

    def destroy_candidates!
      destroyed_ids = []
      skipped_ids   = []

      candidates.each do |import|
        if still_safe_to_destroy?(import)
          import.destroy!
          destroyed_ids << import.id
        else
          skipped_ids << import.id
        end
      end

      [destroyed_ids, skipped_ids]
    end

    # Re-check immediately before destroy: a concurrent stamp or batch record
    # must not let APPLY delete a now-known or in-flight Import.
    def still_safe_to_destroy?(import)
      import.reload
      import.following? &&
        import.follow_import_pipeline_version.nil? &&
        !FollowImportBatch.exists?(import_id: import.id)
    rescue ActiveRecord::RecordNotFound
      false
    end
  end
end
