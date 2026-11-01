# frozen_string_literal: true

class GroupInitialFollows::Worker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 8

  def perform(request_id)
    record = GroupInitialFollow.find_by(group_creation_request_id: request_id)
    return if record.nil?

    GroupInitialFollows::Perform.call(record)
  end
end
