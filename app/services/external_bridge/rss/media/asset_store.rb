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

        def self.fail!(url_digest, kind, revision, code, terminal: false)
          asset = ExternalMediaAsset.find_or_initialize_by(url_digest: url_digest)
          # New rows default state to ready before they are saved. Only a
          # persisted ready file should stop a failure from being recorded.
          return asset if asset.persisted? && asset.ready?

          asset.kind = kind
          asset.state = 'failed'
          asset.failure_code = code.to_s.first(64)
          asset.failed_revision = revision.to_s.first(80)
          asset.attempt_count = terminal ? 3 : asset.attempt_count.to_i + 1
          asset.fetched_at = Time.current
          asset.save!
          asset
        rescue ActiveRecord::RecordNotUnique
          ExternalMediaAsset.find_by(url_digest: url_digest)
        end

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
            fetched_at: Time.current,
          }
        end
      end
    end
  end
end
