#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative 'settings_service_catalog/check'

options = {
  root: File.expand_path('..', __dir__),
  catalog: nil,
}
OptionParser.new do |parser|
  parser.on('--root PATH') { |value| options[:root] = value }
  parser.on('--catalog PATH') { |value| options[:catalog] = value }
end.parse!

catalog = options[:catalog] || File.join(options[:root], 'docs/settings_service/catalog.yml')
result = SettingsServiceCatalog::Check.new(root: options[:root], catalog_path: catalog).run

puts "entries: #{result['entries']}"
puts "by_disposition: #{result['by_disposition']}"
puts "by_audit_status: #{result['by_audit_status']}"
puts "unresolved_entries: #{result['unresolved_entries']}"
puts "unresolved_questions: #{result['unresolved_questions']}"
puts "duplicate keys: #{result['errors'].any? { |error| error.start_with?('duplicate keys') } ? result['errors'].grep(/duplicate/).join : 0}"
result['warnings'].each { |warning| puts "warning: #{warning}" }
result['errors'].each { |error| warn "error: #{error}" }
exit(result['ok'] ? 0 : 1)
