# frozen_string_literal: true

require 'csv'

# Operator-only cleanup of leftover unmarked follow Imports (legacy /
# provenance-unknown). Never used by the watchdog or ProcessImportWorker.
#
# ROLLING DEPLOY: do not run apply until every web / Sidekiq / scheduler
# process is on a revision that persists follow_import_pipeline_version
# *before* enqueue. Old web processes still create unmarked Imports that
# would look like legacy. Always dry-run first.
module FollowImport
  class LegacyCleanup
    REPORT_HEADERS = %w(import_id account_id username created_at overwrite data_file_name data_file_size).freeze

    Result = Struct.new(:before, :apply, :candidates, :destroyed_ids, :manifest_path, keyword_init: true)

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
      destroyed_ids = @apply ? destroy_candidates! : []

      Result.new(
        before: @before,
        apply: @apply,
        candidates: candidates,
        destroyed_ids: destroyed_ids,
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
      candidates.map do |import|
        import.destroy!
        import.id
      end
    end
  end
end
