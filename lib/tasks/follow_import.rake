# frozen_string_literal: true

namespace :follow_import do
  # Operator maintenance: list or destroy leftover unmarked follow Imports.
  #
  # These rows predate the recovery-aware pipeline (follow_import_pipeline_version
  # IS NULL) and have no FollowImportBatch. The watchdog must never re-enqueue
  # them. This task is the only supported way to delete them.
  #
  # ROLLING DEPLOY: do not run APPLY=1 until every web / Sidekiq / scheduler
  # process is on a revision that persists follow_import_pipeline_version before
  # ProcessImportWorker.perform_async. Old web processes still create unmarked
  # Imports. Always dry-run first.
  #
  # BEFORE is required (ISO8601 or any Time.parse-able string). There is no
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
    puts "destroyed=#{result.destroyed_ids.size}" if apply
    puts "manifest=#{result.manifest_path}" if result.manifest_path
  end
end
