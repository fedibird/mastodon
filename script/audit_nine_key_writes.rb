#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'settings_service_catalog/nine_key_write_audit'

root = File.expand_path('..', __dir__)
audit = SettingsServiceCatalog::NineKeyWriteAudit
result = audit.new(root).call
puts "scanned_files: #{result['scanned_files']}"
puts "violations: #{result['violations'].size}"
puts "dynamic_reviews: #{result['reviews'].size}"
puts "allowed_reviews: #{result['allowed_reviews'].size}"
puts "unlisted_reviews: #{result['unlisted_reviews'].size}"
puts 'allowlist:'
audit::ALLOW.each do |entry|
  puts "  #{entry[:path]} #{entry[:method]} #{entry[:kind]} #{entry[:reason]}"
end
result['violations'].each do |finding|
  warn "violation: #{finding.path}:#{finding.line} #{finding.defn} #{finding.kind} #{finding.detail}"
end
result['unlisted_reviews'].each do |finding|
  warn "unlisted: #{finding.path}:#{finding.line} #{finding.defn} #{finding.kind} #{finding.detail}"
end
exit(result['ok'] ? 0 : 1)
