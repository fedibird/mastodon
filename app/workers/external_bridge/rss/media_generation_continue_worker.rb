# frozen_string_literal: true

module ExternalBridge
  module RSS
    # The next batch of a generation swap. No unique lock: this job enqueues
    # its successor before it returns, and until_executed would drop that
    # push. A duplicate is safe. Revalidate holds the URL lock, and a second
    # pass resumes the same checkpoint.
    class MediaGenerationContinueWorker
      include Sidekiq::Worker

      sidekiq_options queue: 'pull', retry: 3

      def perform(resource_id, url_digest)
        MediaRevalidateWorker.new.perform(resource_id, url_digest)
      end
    end
  end
end
