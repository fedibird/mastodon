#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'settings_service_catalog/build'
require_relative 'settings_service_catalog/emit'

root = File.expand_path('..', __dir__)
destination = ARGV[0] || File.join(root, 'docs/settings_service/catalog.yml')
document = SettingsServiceCatalog::Build.new(root).document
File.write(destination, SettingsServiceCatalog::Emit.call(document))
puts "wrote #{destination} entries=#{document['entries'].size}"
