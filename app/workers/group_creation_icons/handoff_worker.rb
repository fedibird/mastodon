# frozen_string_literal: true

class GroupCreationIcons::HandoffWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'pull', retry: 8

  def perform(request_id)
    request = GroupCreationRequest.find_by(id: request_id)
    return if request.nil?

    GroupCreationIcons::Copy.call(request)
  end
end
