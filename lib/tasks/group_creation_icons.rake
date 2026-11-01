# frozen_string_literal: true

namespace :group_creation_icons do
  desc 'Delete private group-request icons that no request row references and that are older than the grace period'
  task sweep: :environment do
    deleted = GroupCreationIcons::Sweep.call
    puts "deleted #{deleted} unreferenced group creation icon(s)"
  end

  desc 'Retry deletion of staged icons for cancelled or rejected requests'
  task purge_terminal: :environment do
    counts = GroupCreationIcons::Purge.purge_terminal
    puts "purged #{counts[:purged]} group creation icon(s), #{counts[:failed]} still need a retry"
  end
end
