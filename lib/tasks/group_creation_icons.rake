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

  desc 'Retry approved icon copies and deletion of the private original'
  task handoff: :environment do
    counts = GroupCreationIcons::HandoffRecovery.call
    puts "finished #{counts[:finished]} group creation icon handoff(s), #{counts[:pending]} still pending, #{counts[:failed]} failed"
  end

  desc 'Reset exhausted approved icon copies and run one handoff pass'
  task resume: :environment do
    resumed = 0
    GroupCreationIcons::HandoffRecovery.exhausted_scope.find_each do |request|
      request.resume_icon_handoff!
      resumed += 1
    end
    counts = GroupCreationIcons::HandoffRecovery.call
    puts "resumed #{resumed} exhausted group creation icon handoff(s); finished #{counts[:finished]}, #{counts[:pending]} still pending, #{counts[:failed]} failed"
  end
end
