# frozen_string_literal: true

namespace :follow_import do
  # Operator maintenance: list or destroy leftover unmarked follow Imports.
  #
  # These rows predate the recovery-aware pipeline (follow_import_pipeline_version
  # IS NULL) and have no FollowImportBatch. The watchdog must never re-enqueue
  # them. Unknown non-NULL versions are not leftover and are never deleted.
  # This task is the only supported way to delete leftover rows.
  #
  # INCIDENT-SAFE ROLLOUT
  #   1. Stop the old FollowImportCsvCleanupScheduler recovery pass before the
  #      migration/code switch (that query has no version guard).
  #   2. During a rolling deploy, pause Follow Import acceptance, or wait until
  #      every web process writes the current marker and no unmarked jobs from
  #      old web processes remain in Sidekiq (queue / retry / scheduled), then
  #      switch Sidekiq/scheduler to this revision.
  #   3. Do not run APPLY=1 until every web / Sidekiq / scheduler process is on
  #      this revision. Always dry-run first.
  #
  # BEFORE is required (ISO8601 or any Time.zone.parse-able string). There is no
  # default cutoff; omitting it refuses to run.
  #
  # Examples:
  #   BEFORE=2026-09-01T00:00:00Z bundle exec rake follow_import:legacy_cleanup
  #   BEFORE=2026-09-01T00:00:00Z MANIFEST=/tmp/legacy-follow-imports.csv bundle exec rake follow_import:legacy_cleanup
  #   BEFORE=2026-09-01T00:00:00Z APPLY=1 bundle exec rake follow_import:legacy_cleanup
  desc 'Dry-run (default) or APPLY leftover unmarked follow Imports older than BEFORE'
  task legacy_cleanup: :environment do
    before = ENV['BEFORE']
    if before.blank?
      abort 'BEFORE is required (e.g. BEFORE=2026-09-01T00:00:00Z). Refusing to run without a cutoff.'
    end

    apply         = ENV['APPLY'] == '1'
    manifest_path = ENV['MANIFEST']
    cleanup       = FollowImport::LegacyCleanup.new(before: before, apply: apply, manifest_path: manifest_path)
    result        = cleanup.call

    puts "mode=#{apply ? 'APPLY' : 'dry-run'} before=#{result.before.iso8601} count=#{result.candidates.size}"
    puts FollowImport::LegacyCleanup::REPORT_HEADERS.join("\t")
    result.candidates.each do |import|
      row = cleanup.row_for(import)
      puts FollowImport::LegacyCleanup::REPORT_HEADERS.map { |key| row[key] }.join("\t")
    end
    puts "destroyed=#{result.destroyed_ids.size} skipped=#{result.skipped_ids.size}" if apply
    puts "manifest=#{result.manifest_path}" if result.manifest_path
  end
end
