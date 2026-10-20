# frozen_string_literal: true

# Rails 6.1 defines db:schema:dump and db:schema:load with :load_config only.
# Initializers do not run, so SchemaDumper never sees ExternalBridge::SchemaDump
# and schema:load cannot resolve ExternalBridge::Schema::DEFINITIONS_SQL.
# Adding :environment makes the hook and the constant available first.
# Do not replace the retained db/schema.rb with an unedited dump: that dump
# drops the hand-written emoji INCLUDE indexes.
task 'db:schema:dump' => :environment
task 'db:schema:load' => :environment
