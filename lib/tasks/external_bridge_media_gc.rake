# frozen_string_literal: true

namespace :external_bridge do
  namespace :media_gc do
    desc 'Print external media GC counts and sample decisions. Does not delete files.'
    task diagnose: :environment do
      report = ExternalBridge::MediaGc.diagnose
      payload = report.merge(samples: report[:samples].map { |row| row.transform_values(&:to_s) })
      puts JSON.generate(payload)
    end

    desc 'Move failed external media GC intents back to pending. Does not delete files.'
    task requeue_failed: :environment do
      moved = ExternalBridge::MediaGc.requeue_failed!
      puts "requeued=#{moved}"
    end
  end
end
