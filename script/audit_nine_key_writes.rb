#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'settings_service_catalog/nine_key_write_audit'

root = File.expand_path('..', __dir__)
result = SettingsServiceCatalog::NineKeyWriteAudit.new(root).call
puts "scanned_files: #{result['scanned_files']}"
puts "violations: #{result['violations'].size}"
puts "dynamic_reviews: #{result['reviews'].size}"
result['violations'].each do |finding|
  warn "violation: #{finding.path}:#{finding.line} #{finding.kind} #{finding.detail}"
end
unlisted = result['reviews'].reject { |finding| SettingsServiceCatalog::NineKeyWriteAudit::ALLOW.key?(finding.path) }
puts "unlisted_dynamic_reviews: #{unlisted.size}"
unlisted.each do |finding|
  warn "review: #{finding.path}:#{finding.line} #{finding.detail}"
end
exit(result['ok'] ? 0 : 1)
