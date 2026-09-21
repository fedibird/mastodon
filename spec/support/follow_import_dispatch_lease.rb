# frozen_string_literal: true

# schema.rb does not insert the singleton dispatch-lease row. Migrations do.
# Keep the test database fail-closed-ready after db:schema:load.
RSpec.configure do |config|
  config.before(:suite) do
    connection = ActiveRecord::Base.connection
    next unless connection.data_source_exists?('follow_import_dispatch_leases')

    FollowImportDispatchLease.find_or_create_by!(id: FollowImportDispatchLease::SINGLETON_ID) do |row|
      row.fencing_generation = 0
    end
  end
end
