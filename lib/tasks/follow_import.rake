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

  # Read-only offline pacing backtest. Compares candidate profiles against
  # exported telemetry CSVs. Never writes Follow Import rows, Redis, or
  # federation. TRANSPORT and SCENARIOS are required. TICKS and DISPATCH
  # are optional. Example:
  #
  #   TRANSPORT=/tmp/transport.csv \
  #   TICKS=/tmp/scheduler_ticks.csv \
  #   DISPATCH=/tmp/dispatch_passes.csv \
  #   SCENARIOS=/tmp/scenarios.json \
  #   OUT_JSON=/tmp/follow-import-pacing-backtest.json \
  #   OUT_MD=/tmp/follow-import-pacing-backtest.md \
  #   bundle exec rake follow_import:pacing_backtest
  desc 'Read-only Follow Import pacing backtest against exported telemetry CSVs'
  task pacing_backtest: :environment do
    missing = %w(TRANSPORT SCENARIOS).select { |key| ENV[key].to_s.strip.empty? }
    abort "missing required env: #{missing.join(', ')}" if missing.any?

    begin
      result = FollowImport::PacingBacktest.call(
        transport: ENV['TRANSPORT'],
        ticks: ENV['TICKS'],
        dispatch: ENV['DISPATCH'],
        scenarios: ENV['SCENARIOS'],
        out_json: ENV['OUT_JSON'],
        out_md: ENV['OUT_MD']
      )
      puts "schema=#{result['schema']} schema_version=#{result['schema_version']} scenarios=#{Array(result['scenarios']).length}"
      puts "json=#{ENV['OUT_JSON']}" if ENV['OUT_JSON'].present?
      puts "md=#{ENV['OUT_MD']}" if ENV['OUT_MD'].present?
    rescue FollowImport::PacingBacktest::Error => e
      abort e.message
    end
  end
end
