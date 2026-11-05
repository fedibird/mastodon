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
        # source_refs cite file:line from this worktree. Re-run the builder in the
        # same change that moves a cited line. CI runs the check on pull requests.
        # read_line follows its snippet. A literal file:line in the builder does
        # not. When that line moves but stays non-blank, update the literal before
        # regenerating. The check rejects a missing file, an out-of-range line, and
        # a blank line. It does not reject a different non-blank statement.
      YAML
      header + YAML.dump(document)
    end
  end
end
