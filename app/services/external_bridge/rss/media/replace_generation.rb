# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Installs a verified new body before any projection is repointed, then
      # moves every link and only then plans the previous file for GC. A
      # failure rolls the database back and leaves the previous attachment.
      class ReplaceGeneration
        def self.call!(asset, result, resource, url_digest)
          new(asset, result, resource, url_digest).call!
        end

        def initialize(asset, result, resource, url_digest)
          @asset = asset
          @result = result
          @resource = resource
          @url_digest = url_digest
        end

        def call!
          markers = []
          ApplicationRecord.transaction do
            fresh = ExternalMediaAsset.lock.find(@asset.id)
            raise ActiveRecord::Rollback unless fresh.ready? && fresh.url_digest == @url_digest

            incoming = write_incoming!(fresh)
            old_attachment_ids = repoint!(fresh, incoming)
            retire!(fresh, incoming)
            ExternalBridge::MediaGc.plan_generation!(fresh.id)
            ExternalBridge::MediaGc.schedule_release!(attachment_ids: old_attachment_ids, asset_ids: [fresh.id])
            markers = marker_ids(incoming)
          end
          notify!(markers)
        end

        private

        def write_incoming!(fresh)
          extension = AssetStore::EXTENSIONS.fetch(@result.type)
          asset = ExternalMediaAsset.new(url_digest: "incoming:#{fresh.id}:#{SecureRandom.hex(4)}", kind: 'image', state: 'ready', generation: fresh.generation.to_i + 1)
          Tempfile.create(['rss-generation', ".#{extension}"], binmode: true) do |file|
            file.write(@result.body)
            file.flush
            file.rewind
            asset.file = file
            asset.file_content_type = @result.content_type
            asset.assign_attributes(incoming_attributes)
            asset.save!
          end
          asset
        end

        def incoming_attributes
          {
            content_type: @result.content_type,
            byte_size: @result.body.bytesize,
            fingerprint: @result.fingerprint,
            width: @result.width,
            height: @result.height,
            validator_etag: @result.etag.to_s.first(500).presence,
            validator_last_modified: @result.last_modified.to_s.first(500).presence,
            validated_at: Time.current,
            revalidate_after: nil,
            revalidate_attempt: 0,
            fetched_at: Time.current,
            failure_code: nil,
            attempt_count: 0,
          }
        end

        def repoint!(fresh, incoming)
          old_ids = []
          ExternalProjectionAttachment.where(external_media_asset_id: fresh.id).includes(:media_attachment).find_each do |link|
            previous = link.media_attachment
            next if previous.nil?

            copied = copy_attachment(previous)
            ExternalBridge::MediaGc.plan_replacement!(attachment_ids: [previous.id], asset_ids: [])
            link.update!(external_media_asset: incoming, media_attachment: copied)
            old_ids << previous.id
          end
          old_ids
        end

        def copy_attachment(previous)
          extension = AssetStore::EXTENSIONS.fetch(@result.type, 'bin')
          Tempfile.create(['rss-repoint', ".#{extension}"], binmode: true) do |file|
            file.write(@result.body)
            file.flush
            file.rewind
            MediaAttachment.create!(
              account_id: previous.account_id,
              status_id: previous.status_id,
              file: file,
              description: previous.description,
              remote_url: ''
            )
          end
        end

        def retire!(fresh, incoming)
          fresh.update_columns(
            url_digest: "superseded:#{fresh.id}",
            state: 'failed',
            failure_code: 'superseded',
            updated_at: Time.current
          )
          incoming.update_columns(url_digest: @url_digest, updated_at: Time.current)
          AssetResource.remember!(incoming.id, @resource.id)
        end

        def marker_ids(incoming)
          ExternalProjectionAttachment.where(external_media_asset_id: incoming.id).pluck(:external_status_projection_id)
        end

        def notify!(ids)
          ExternalStatusProjection.where(id: ids).find_each { |marker| Sync.notify!(marker) }
        rescue StandardError => e
          Rails.logger.info("[ExternalBridge::RSS] media generation notify skipped error=#{e.class}")
        end
      end
    end
  end
end
