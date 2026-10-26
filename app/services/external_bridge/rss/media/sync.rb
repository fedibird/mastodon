# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Copies ready shared images onto one projection as ordinary
      # MediaAttachments. Remote video and audio are not attachments.
      # Order follows the candidate list. A change of order rebuilds the
      # attachment rows so the default id order matches the article.
      class Sync
        def self.attach_ready!(marker, resource)
          new(marker, resource).attach_ready!
        end

        def self.enqueue!(resource)
          new(nil, resource).enqueue!
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

          changed = reconcile(desired_images)
          notify! if changed && allow_notify
          changed
        end

        def enqueue!
          return if @resource.nil? || @resource.media_revision.blank? || @resource.source_deleted_at.present?

          image_candidates.each do |candidate|
            digest = MediaDigest.url_digest(candidate['url'])
            asset = ExternalMediaAsset.find_by(url_digest: digest)
            next if asset&.ready? || asset&.exhausted_for?(@resource.media_revision)

            MediaFetchWorker.perform_async(@resource.id, @resource.media_revision, digest)
          end
        end

        private

        def eligible?
          return false if @marker.nil? || @resource.nil? || @marker.status.nil?
          return false if @marker.source_deleted || @resource.source_deleted_at.present?

          subscription = @marker.external_subscription
          subscription&.state == 'active' && subscription.user&.functional? && Feature.permitted?(subscription.user)
        end

        def desired_images
          image_candidates.filter_map do |candidate|
            asset = AssetStore.ready(MediaDigest.url_digest(candidate['url']))
            next if asset.nil?

            [candidate, asset]
          end.first(attachment_limit)
        end

        def image_candidates
          Array(@resource.media_candidates).select { |candidate| candidate['kind'] == 'image' && candidate['url'].present? }
        end

        def attachment_limit
          configured = Setting.attachments_max.to_i
          configured = 4 if configured <= 0
          [configured, MediaAttachment::ATTACHMENTS_LIMIT].min
        end

        def reconcile(desired)
          current = @marker.external_projection_attachments.order(:position, :id).to_a
          return update_descriptions(current, desired) if same_assets?(current, desired)

          replace(current, desired)
          true
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

        def replace(current, desired)
          released = []
          current.each do |row|
            released << row.external_media_asset_id
            attachment = row.media_attachment
            row.destroy!
            attachment&.destroy!
          end
          desired.each_with_index { |(candidate, asset), index| create_link!(candidate, asset, index) }
          release_assets(released - desired.map { |_, asset| asset.id })
        end

        def create_link!(candidate, asset, index)
          attachment = nil
          attachment = copy_attachment!(asset, alt_text(candidate))
          @marker.external_projection_attachments.create!(
            external_media_asset: asset,
            media_attachment: attachment,
            position: index,
            kind: 'image'
          )
        rescue ActiveRecord::RecordInvalid, Paperclip::Error => e
          attachment&.destroy!
          Rails.logger.info("[ExternalBridge::RSS] media attach failed error=#{e.class}")
          nil
        end

        def copy_attachment!(asset, description)
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

          'bin'
        end

        def alt_text(candidate)
          candidate['description'].to_s.strip.slice(0, MediaAttachment::MAX_DESCRIPTION_LENGTH).presence
        end

        def release_assets(ids)
          ExternalMediaAsset.where(id: ids.uniq).find_each do |asset|
            next if asset.external_projection_attachments.exists?

            asset.destroy!
          end
        end

        def notify!
          self.class.notify!(@marker)
        end
      end
    end
  end
end
