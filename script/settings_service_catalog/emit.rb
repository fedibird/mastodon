# frozen_string_literal: true

require 'yaml'

module SettingsServiceCatalog
  module Emit
    module_function

    def call(document)
      header = <<~YAML
        # Audit inventory for the Fedibird Settings Service.
        # This file is not a public API contract and is not loaded by production code.
        # Regenerate with: ruby script/build_settings_service_catalog.rb
        # Check with: ruby script/check_settings_service_catalog.rb
      YAML
      header + YAML.dump(document)
    end
  end
end
