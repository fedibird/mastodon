# frozen_string_literal: true

namespace :group_creation_icons do
  desc 'Delete private group-request icons that no request row references and that are older than the grace period'
  task sweep: :environment do
    deleted = GroupCreationIcons::Sweep.call
    puts "deleted #{deleted} unreferenced group creation icon(s)"
  end

  desc 'Retry deletion of staged icons for cancelled or rejected requests'
  task purge_terminal: :environment do
    scope = GroupCreationRequest.where(state: GroupCreationRequest.states.values_at('rejected', 'cancelled'))
    scope = scope.where.not(icon_storage_key: nil).where(icon_purged_at: nil)
    scope.find_each { |request| GroupCreationIcons::Purge.call(request) }
  end
end
