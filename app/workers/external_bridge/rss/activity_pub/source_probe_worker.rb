# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      class SourceProbeWorker
        include Sidekiq::Worker

        sidekiq_options queue: 'pull', retry: 3, lock: :until_executed, lock_ttl: 15.minutes.to_i

        def perform(source_id)
          ProbeSource.new.call(source_id)
        end
      end
    end
  end
end
