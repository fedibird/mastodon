# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Copies ready shared images onto one projection as ordinary
      # MediaAttachments. Remote video and audio are not attachments.
      # Order follows the candidate list. A change of order rebuilds the
      # attachment rows so the default id order matches the article.
      class Sync
        COPY_FAILURES = [
          ActiveRecord::RecordInvalid,
          Paperclip::Error,
          Mastodon::StreamValidationError,
          Mastodon::DimensionsValidationError,
        ].freeze

        def self.attach_ready!(marker, resource)
          new(marker, resource).attach_ready!
        end

        def self.enqueue!(resource, videos: false)
          new(nil, resource).enqueue!(videos: videos)
        end

        def self.notify!(marker)
          return if marker.nil? || marker.status_id.blank?

          Status.where(id: marker.status_id).update_all(updated_at: Time.current)
          Rails.cache.delete("statuses/#{marker.status_id}")
          Streaming::Scheduler.bump_and_schedule_content!(marker)
        end

        def initialize(marker, resource)
          @marker = marker
          @resource = resource
        end

        def attach_ready!(allow_notify: false)
          return false unless eligible?

          changed = reconcile(desired_files)
          notify! if changed && allow_notify
          changed
        end

        def enqueue!(videos: false)
          return if @resource.nil? || @resource.media_revision.blank? || @resource.source_deleted_at.present?

          @revalidations = 0
          pending_candidates(videos).each { |candidate| queue_candidate(candidate) }
        end

        private

        def queue_candidate(candidate)
          digest = MediaDigest.url_digest(candidate['url'])
          asset = ExternalMediaAsset.find_by(url_digest: digest)
          if asset&.ready?
            AssetResource.remember!(asset.id, @resource.id)
            queue_revalidation(asset, digest)
            return
          end
          return if asset&.exhausted_for?(@resource.media_revision) || asset&.processing_blocked?(@resource.media_revision)

          MediaFetchWorker.perform_async(@resource.id, @resource.media_revision, digest)
        end

        def queue_revalidation(asset, digest)
          return unless asset.kind == 'image' && Revalidate.due?(asset)
          return if @revalidations >= Limits::MEDIA_REVALIDATE_PER_REFRESH

          @revalidations += 1
          MediaRevalidateWorker.perform_async(@resource.id, digest)
        end

        def eligible?
          return false if @marker.nil? || @resource.nil? || @marker.status.nil?
          return false if @marker.source_deleted || @resource.source_deleted_at.present?

          subscription = @marker.external_subscription
          subscription&.state == 'active' && subscription.user&.functional? && Feature.permitted?(subscription.user)
        end

        def desired_files
          saved_candidates.filter_map do |candidate|
            asset = attachable_asset(MediaDigest.url_digest(candidate['url']))
            next if asset.nil? || asset.kind != candidate['kind']

            [candidate, asset]
          end.first(attachment_limit)
        end

        # A processing failure stays remote until its backoff ends. The shared
        # bytes are still on disk, so the retry converts them instead of
        # downloading them again.
        def attachable_asset(digest)
          asset = ExternalMediaAsset.find_by(url_digest: digest)
          return nil if asset.nil?
          return asset if asset.ready?
          return asset if asset.processing_failed? && !asset.processing_blocked?(@resource.media_revision)

          nil
        end

        def saved_candidates
          Array(@resource.media_candidates).select { |candidate| %w(image video).include?(candidate['kind']) && candidate['url'].present? }
        end

        def pending_candidates(videos)
          images = saved_candidates.select { |candidate| candidate['kind'] == 'image' }
          images + video_candidates.select { |candidate| video_due?(candidate, videos) }
        end

        # A new revision may queue a video. A video that already failed for a
        # temporary HTTP error is queued again after a short backoff, without
        # waiting for another revision. Size and type failures are exhausted
        # immediately and are not queued again.
        def video_due?(candidate, videos)
          return false unless Policy.hybrid?

          asset = ExternalMediaAsset.find_by(url_digest: MediaDigest.url_digest(candidate['url']))
          return videos if asset.nil?
          return false if asset.ready? || asset.exhausted_for?(@resource.media_revision)
          return false if asset.processing_blocked?(@resource.media_revision)
          return false if asset.fetched_at.present? && asset.fetched_at > retry_delay(asset).ago

          asset.failed? || asset.processing_failed?
        end

        def retry_delay(asset)
          ExternalMediaAsset.processing_retry_delay(asset.attempt_count)
        end

        def video_candidates
          saved_candidates.select { |candidate| candidate['kind'] == 'video' && video_file?(candidate) }
        end

        def video_file?(candidate)
          return true if Policy.storable_mime?(candidate['mime_hint'])

          extension = File.extname(Addressable::URI.parse(candidate['url'].to_s).path.to_s).downcase
          %w(.mp4 .webm).include?(extension)
        rescue Addressable::URI::InvalidURIError
          false
        end

        def attachment_limit
          configured = Setting.attachments_max.to_i
          configured = 4 if configured <= 0
          [configured, MediaAttachment::ATTACHMENTS_LIMIT].min
        end

        def reconcile(desired, retry_ready: true)
          current = attachment_rows
          return update_descriptions(current, desired) if same_assets?(current, desired)

          prepared = prepare_replacement(current, desired)
          if prepared.nil?
            return false unless retry_ready && @reprocess

            @reprocess = false
            return reconcile(desired_files, retry_ready: false)
          end

          commit_replacement(current, prepared)
        end

        def attachment_rows
          @marker.external_projection_attachments.includes(:media_attachment).order(:position, :id).to_a
        end

        def same_assets?(current, desired)
          current.map(&:external_media_asset_id) == desired.map { |_, asset| asset.id }
        end

        def update_descriptions(current, desired)
          changed = false
          current.each_with_index do |row, index|
            description = alt_text(desired[index].first)
            attachment = row.media_attachment
            next if attachment.nil? || attachment.description.to_s == description.to_s

            attachment.update!(description: description)
            changed = true
          end
          changed
        end

        # New files are built before any existing attachment is removed. A
        # failed video therefore cannot drop an image that was already showing.
        # One retry attaches the files that are still eligible after the
        # failure has been recorded.
        def prepare_replacement(current, desired)
          indexed = current.index_by(&:external_media_asset_id)
          prepared = []
          desired.each do |candidate, asset|
            existing = indexed[asset.id]
            if existing&.media_attachment
              prepared << { kind: :keep, row: existing, candidate: candidate, asset: asset }
              next
            end

            copied = copy_attachment!(asset, alt_text(candidate))
            if copied == :blocked
              next
            elsif copied.nil?
              destroy_new!(prepared)
              return nil
            end

            prepared << { kind: :new, attachment: copied, candidate: candidate, asset: asset }
          end
          prepared
        rescue StandardError
          destroy_new!(prepared)
          raise
        end

        def commit_replacement(current, prepared)
          committed = false
          kept_ids = prepared.filter_map { |item| item[:row]&.id }
          removed = current.reject { |row| kept_ids.include?(row.id) }
          changed = removed.any?

          attachment_ids = removed.map(&:media_attachment_id)
          asset_ids = removed.map(&:external_media_asset_id) - prepared.map { |item| item[:asset].id }
          ApplicationRecord.transaction do
            ExternalBridge::MediaGc.plan_replacement!(attachment_ids: attachment_ids, asset_ids: asset_ids)
            removed.each(&:destroy!)
            prepared.each_with_index do |item, index|
              changed = true if write_prepared!(item, index)
            end
            ExternalBridge::MediaGc.schedule_release!(attachment_ids: attachment_ids, asset_ids: asset_ids)
          end
          committed = true
          changed
        rescue StandardError
          destroy_new!(prepared) unless committed
          raise
        end

        def write_prepared!(item, index)
          return create_prepared!(item, index) unless item[:kind] == :keep

          moved = item[:row].position != index
          item[:row].update!(position: index) if moved
          described = assign_description!(item[:row].media_attachment, item[:candidate])
          moved || described
        end

        def create_prepared!(item, index)
          @marker.external_projection_attachments.create!(
            external_media_asset: item[:asset],
            media_attachment: item[:attachment],
            position: index,
            kind: item[:candidate]['kind']
          )
          AssetStore.mark_processed!(item[:asset])
          true
        end

        def copy_attachment!(asset, description)
          URLLock.exclusive(asset.url_digest) do
            current = ExternalMediaAsset.find_by(id: asset.id)
            if current&.processing_blocked?(@resource.media_revision)
              :blocked
            else
              write_attachment!(asset, description)
            end
          rescue *COPY_FAILURES => e
            record_processing_failure!(asset, e)
          end
        end

        def record_processing_failure!(asset, error)
          fresh = ExternalMediaAsset.find_by(id: asset.id)
          if fresh&.ready? && @marker.external_projection_attachments.exists?(external_media_asset_id: fresh.id)
            return :blocked
          end

          AssetStore.processing_fail!(asset.url_digest, asset.kind, @resource.media_revision, 'processing_failed')
          @reprocess = true
          Rails.logger.info("[ExternalBridge::RSS] media attach failed error=#{error.class}")
          nil
        end

        def write_attachment!(asset, description)
          extension = file_extension(asset)
          Tempfile.create(['rss-attach', ".#{extension}"], binmode: true) do |file|
            asset.file.copy_to_local_file(:original, file.path)
            file.rewind
            MediaAttachment.create!(
              account_id: @marker.account_id,
              status_id: @marker.status_id,
              file: file,
              description: description,
              remote_url: ''
            )
          end
        end

        def file_extension(asset)
          type = asset.content_type.to_s
          return 'jpg' if type == 'image/jpeg'
          return 'png' if type == 'image/png'
          return 'gif' if type == 'image/gif'
          return 'webp' if type == 'image/webp'
          return 'mp4' if type == 'video/mp4'
          return 'webm' if type == 'video/webm'

          'bin'
        end

        def alt_text(candidate)
          candidate['description'].to_s.strip.slice(0, MediaAttachment::MAX_DESCRIPTION_LENGTH).presence
        end

        def assign_description!(attachment, candidate)
          return false if attachment.nil?

          description = alt_text(candidate)
          return false if attachment.description.to_s == description.to_s

          attachment.update!(description: description)
          true
        end

        def destroy_new!(prepared)
          Array(prepared).each { |item| destroy_attachment!(item[:attachment]) if item[:kind] == :new }
        end

        def destroy_attachment!(attachment)
          return if attachment.nil? || !attachment.persisted? || attachment.destroyed?

          attachment.destroy!
        rescue ActiveRecord::ActiveRecordError
          nil
        end

        def notify!
          self.class.notify!(@marker)
        end
      end
    end
  end
end
