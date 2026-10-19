# frozen_string_literal: true

# db:schema:dump reads PostgreSQL tables and foreign keys. It does not read
# trigger functions. Append the application constant so a later schema:load
# still installs the projection guards. This does not rewrite emoji INCLUDE
# indexes; do not replace db/schema.rb with an unedited dump.
#
# This file runs only after the Rails environment boots. db:schema:dump and
# db:schema:load do not boot it on their own. lib/tasks/external_bridge_schema.rake
# adds the :environment prerequisite so the hook is installed before a dump and
# ExternalBridge::Schema is loaded before a load executes the constant.
module ExternalBridge
  module SchemaDump
    def trailer(stream)
      stream.puts '  # Projection triggers and composite foreign keys. Rails 6.1 cannot dump them.'
      stream.puts '  execute ExternalBridge::Schema::DEFINITIONS_SQL'
      stream.puts
      super
    end
  end
end

ActiveRecord::SchemaDumper.prepend(ExternalBridge::SchemaDump)
