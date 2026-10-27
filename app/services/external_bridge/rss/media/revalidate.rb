# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Conditional GET for one ready image. The URL is read from the resource
      # candidate list. A 304 reuses the local file only when that file is
      # still present. A changed body is swapped by ReplaceGeneration, which
      # saves the new generation before it repoints projections in batches.
      # A timeout or HTTP error leaves the current file and sets a backoff.
      #
      # A 304 with a missing shared file marks the asset failed. The
      # revalidate scheduler only selects ready images, so it will not retry
      # that row.
      # After the URL lock is released, follow_up enqueues MediaFetchWorker.
      # That fetch sends no validators. If the job is lost, the next refresh
      # that materializes the resource reaches the same worker:
      # Materialize#project always calls Media::Sync.enqueue!, and a failed
      # asset is queued as a fetch rather than a conditional GET.
      class Revalidate
        NETWORK = [HTTP::Error, IOError, Timeout::Error, Errno::ECONNRESET, SocketError].freeze

        def self.due?(asset, now = Time.current)
          return false unless asset&.ready? && asset.kind == 'image'
          return false if asset.revalidate_after.present? && asset.revalidate_after > now
          return true if asset.validated_at.nil?

          asset.validated_at <= Limits::MEDIA_REVALIDATE_AFTER.ago
        end

        def self.call(resource_id, url_digest)
          new(resource_id, url_digest).call
        end

        def initialize(resource_id, url_digest)
          @resource_id = resource_id
          @url_digest = url_digest
        end

        def call
          return :disabled unless permitted?
          return :missing if candidate.nil? || asset.nil?

          outcome = URLLock.exclusive(@url_digest) { locked }
          follow_up(outcome)
          outcome
        end

        private

        def permitted?
          return false unless Feature.enabled?

          ExternalSubscription.where(external_source_id: resource&.external_source_id, state: 'active').includes(:user).any? do |subscription|
            subscription.user&.functional? && Feature.permitted?(subscription.user)
          end
        end

        def locked
          current = ExternalMediaAsset.find_by(url_digest: @url_digest)
          return :missing unless current&.ready? && current.kind == 'image'
          return :fresh unless self.class.due?(current)

          apply(current)
        rescue *NETWORK, ExternalBridge::Error => e
          backoff(current, code_for(e))
          :failed
        end

        def apply(current)
          return ReplaceGeneration.resume!(current, resource, @url_digest) if ReplaceGeneration.pending?(current)

          result = ImageFetch.new.call(source_url, etag: current.validator_etag, last_modified: current.validator_last_modified)
          if result.not_modified
            unchanged_or_missing(current)
          elsif file_intact?(current) && result.fingerprint == current.fingerprint
            touch(current, result)
            :unchanged
          else
            ReplaceGeneration.call!(current, result, resource, @url_digest)
          end
        end

        # 304 has no body. The shared file is restored by the unconditional
        # fetch follow_up enqueues, not by another conditional GET. Existing
        # projection attachments stay in place.
        def unchanged_or_missing(current)
          unless file_intact?(current)
            current.update_columns(state: 'failed', failure_code: 'local_missing', validated_at: Time.current, updated_at: Time.current)
            Rails.logger.info("[ExternalBridge::RSS] media revalidate failed asset_id=#{current.id} code=local_missing")
            return :local_missing
          end

          touch(current, nil)
          :not_modified
        end

        def touch(current, result)
          now = Time.current
          attributes = { validated_at: now, revalidate_after: nil, revalidate_attempt: 0, updated_at: now }
          if result
            attributes[:validator_etag] = result.etag.to_s.first(500).presence
            attributes[:validator_last_modified] = result.last_modified.to_s.first(500).presence
          end
          current.update_columns(attributes)
        end

        def backoff(current, code)
          return if current.nil? || !current.persisted?

          attempt = current.revalidate_attempt.to_i + 1
          delay = attempt >= 3 ? 7.days : ExternalMediaAsset.processing_retry_delay(attempt)
          current.update_columns(
            revalidate_attempt: attempt,
            revalidate_after: Time.current + delay,
            failure_code: code.to_s.first(64),
            updated_at: Time.current
          )
          Rails.logger.info("[ExternalBridge::RSS] media revalidate failed asset_id=#{current.id} code=#{code}")
        end

        # Enqueued only after URLLock.exclusive returns. Fetch and a resumed
        # revalidate take that lock themselves.
        def follow_up(outcome)
          case outcome
          when :partial
            MediaGenerationContinueWorker.perform_async(@resource_id, @url_digest)
          when :local_missing
            enqueue_refetch!
          end
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] media revalidate follow-up skipped error=#{e.class}")
        end

        # The worker is keyed by the representative digest. A primary image
        # uses this asset's digest. A stored fallback uses the representative
        # so ImageAttempts walks the same chain and can restore that file.
        def enqueue_refetch!
          revision = resource&.media_revision
          primary = candidate && candidate['url']
          return if revision.blank? || primary.blank?

          MediaFetchWorker.perform_async(@resource_id, revision, MediaDigest.url_digest(primary))
        end

        def file_intact?(current)
          current.file_file_name.present? && current.file.exists?
        rescue StandardError
          false
        end

        def code_for(error)
          return error.code if error.respond_to?(:code) && error.code.present?

          'fetch_failed'
        end

        def resource
          @resource ||= ExternalResource.find_by(id: @resource_id)
        end

        def asset
          ExternalMediaAsset.ready.find_by(url_digest: @url_digest, kind: 'image')
        end

        def candidate
          return @candidate if defined?(@candidate)

          @candidate = Array(resource&.media_candidates).find do |row|
            row['kind'] == 'image' && source_urls(row).any? { |url| MediaDigest.url_digest(url) == @url_digest }
          end
        end

        def source_url
          request = ImageAttempts.requests(candidate).find { |item| MediaDigest.url_digest(item.store) == @url_digest }
          request&.get
        end

        def source_urls(row)
          ImageAttempts.requests(row).map(&:store)
        end
      end
    end
  end
end
