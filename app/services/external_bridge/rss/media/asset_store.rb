# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Writes the shared original bytes. Paperclip stores them unchanged.
      # A second subscriber reuses the row and does not download again.
      class AssetStore
        EXTENSIONS = { png: 'png', jpeg: 'jpg', gif: 'gif', webp: 'webp', mp4: 'mp4', webm: 'webm' }.freeze

        def self.ready(url_digest)
          ExternalMediaAsset.ready.find_by(url_digest: url_digest)
        end

        def self.store!(url_digest:, kind:, revision:, result:)
          new(url_digest, kind, revision, result).store!
        end

        def self.mark_processed!(asset)
          return asset if asset.nil? || asset.ready?

          asset.update!(state: 'ready', failure_code: nil, failed_revision: nil, attempt_count: 0)
          asset
        end

        # The shared file stays on disk. Ready rows are left alone when another
        # worker already attached them. A new media revision starts at one try.
        def self.processing_fail!(url_digest, kind, revision, code)
          ApplicationRecord.transaction do
            asset = ExternalMediaAsset.lock.find_or_initialize_by(url_digest: url_digest)
            return asset if asset.processing_blocked?(revision)

            revision_key = revision.to_s.first(80)
            attempts = asset.failed_revision.to_s == revision_key ? asset.attempt_count.to_i + 1 : 1
            # update_columns skips Paperclip. Re-validating a broken video on
            # the way to the failure state would raise and leave the row ready.
            attributes = {
              kind: kind,
              state: 'processing_failed',
              failure_code: code.to_s.first(64),
              failed_revision: revision_key,
              attempt_count: attempts,
              fetched_at: Time.current,
              updated_at: Time.current,
            }
            if asset.new_record?
              asset.assign_attributes(attributes)
              asset.save!
            else
              asset.update_columns(attributes)
              asset.reload
            end
            asset
          end
        rescue ActiveRecord::RecordNotUnique
          ExternalMediaAsset.find_by(url_digest: url_digest)
        end

        # The representative URL was skipped because a later candidate stored
        # the bytes. The row has no file. While a current fallback is ready the
        # next refresh does not GET this URL. attempt_count stays 0, so this
        # marker is not exhaustion. When no current fallback is ready the
        # chain runs again and a later terminal failure starts a fresh budget.
        def self.mark_alternate!(url_digest, revision, fingerprint: nil, attempt_log: nil)
          asset = ExternalMediaAsset.find_or_initialize_by(url_digest: url_digest)
          return asset if asset.persisted? && asset.ready?

          asset.kind = 'image'
          asset.state = 'failed'
          asset.failure_code = 'alternate_selected'
          asset.failed_revision = revision.to_s.first(80)
          asset.attempt_count = 0
          asset.fetched_at = Time.current
          asset.candidate_fingerprint = fingerprint if fingerprint.present?
          asset.attempt_log = sanitize_attempt_log(attempt_log) unless attempt_log.nil?
          asset.save!
          asset
        rescue ActiveRecord::RecordNotUnique
          ExternalMediaAsset.find_by(url_digest: url_digest)
        end

        # A fallback URL's own failure. The representative row owns the
        # exhaustion budget, so this observation does not set a fingerprint
        # or a revision and does not overwrite a ready file or a row that
        # already tracks a candidate set.
        def self.record_miss!(url_digest, code)
          asset = ExternalMediaAsset.find_or_initialize_by(url_digest: url_digest)
          return asset if asset.persisted? && (asset.ready? || asset.alternate_selected? || asset.candidate_fingerprint.present?)
          return asset if asset.persisted? && asset.kind.present? && asset.kind != 'image'
          return asset if asset.persisted? && asset.attempt_count.to_i >= 3 && asset.failed_revision.present?

          asset.kind = 'image'
          asset.state = 'failed'
          asset.failure_code = code.to_s.first(64)
          asset.failed_revision = nil
          asset.attempt_count = 0
          asset.fetched_at = Time.current
          asset.save!
          asset
        rescue ActiveRecord::RecordNotUnique
          ExternalMediaAsset.find_by(url_digest: url_digest)
        end

        def self.fail!(url_digest, kind, revision, code, terminal: false, fingerprint: nil, attempt_log: nil)
          asset = ExternalMediaAsset.find_or_initialize_by(url_digest: url_digest)
          # New rows default state to ready before they are saved. Only a
          # persisted ready file should stop a failure from being recorded.
          return asset if asset.persisted? && asset.ready?

          previous = asset.candidate_fingerprint
          asset.kind = kind
          asset.state = 'failed'
          asset.failure_code = code.to_s.first(64)
          asset.failed_revision = revision.to_s.first(80)
          asset.attempt_count = next_attempt_count(asset, previous, fingerprint, terminal)
          asset.candidate_fingerprint = fingerprint if fingerprint.present?
          asset.attempt_log = sanitize_attempt_log(attempt_log) unless attempt_log.nil?
          asset.fetched_at = Time.current
          asset.save!
          asset
        rescue ActiveRecord::RecordNotUnique
          ExternalMediaAsset.find_by(url_digest: url_digest)
        end

        # Digests and codes only. A URL is never written onto the shared row.
        def self.sanitize_attempt_log(log)
          Array(log).first(Limits::MAX_IMAGE_FETCH_ATTEMPTS).filter_map do |row|
            source = row.respond_to?(:to_h) ? row.to_h.stringify_keys : {}
            digest = source['digest'].to_s
            code = source['code'].to_s
            next unless digest.match?(/\A[0-9a-f]{64}\z/) && code.present?

            { 'digest' => digest, 'code' => code.first(64) }
          end
        end

        def self.next_attempt_count(asset, previous, fingerprint, terminal)
          return 3 if terminal
          return 1 if fingerprint.present? && previous.present? && previous != fingerprint

          asset.attempt_count.to_i + 1
        end
        private_class_method :next_attempt_count

        def initialize(url_digest, kind, revision, result)
          @url_digest = url_digest
          @kind = kind
          @revision = revision
          @result = result
        end

        def store!
          ApplicationRecord.transaction do
            existing = ExternalMediaAsset.lock.find_by(url_digest: @url_digest)
            return existing if existing&.ready?

            write!
          end
        rescue ActiveRecord::RecordNotUnique
          AssetStore.ready(@url_digest)
        end

        private

        def write!
          extension = EXTENSIONS.fetch(@result.type)
          asset = ExternalMediaAsset.find_or_initialize_by(url_digest: @url_digest)
          Tempfile.create(['rss-media', ".#{extension}"], binmode: true) do |file|
            file.write(@result.body)
            file.flush
            file.rewind
            asset.file = file
            asset.file_content_type = @result.content_type
            asset.assign_attributes(attributes)
            asset.save!
          end
          asset
        end

        def header_value(name)
          return nil unless @result.respond_to?(name)

          @result.public_send(name).to_s.first(500).presence
        end

        def attributes
          {
            kind: @kind,
            state: 'ready',
            content_type: @result.content_type,
            byte_size: @result.body.bytesize,
            fingerprint: @result.fingerprint,
            width: @result.width,
            height: @result.height,
            failure_code: nil,
            failed_revision: nil,
            attempt_count: 0,
            candidate_fingerprint: nil,
            attempt_log: [],
            fetched_at: Time.current,
            validator_etag: header_value(:etag),
            validator_last_modified: header_value(:last_modified),
            validated_at: Time.current,
            revalidate_after: nil,
            revalidate_attempt: 0,
          }
        end
      end
    end
  end
end
