# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Installs one verified generation, then repoints projections in short
      # transactions. The checkpoint is the incoming row: its digest is
      # incoming:{old_id} and its generation is the next generation id. A
      # second pass finds that row and does not allocate another one.
      #
      # Each pass moves at most MEDIA_REPOINT_BATCH projections, one
      # transaction per subscriber, and does not hold ExternalMediaAsset's
      # row lock across Paperclip. The previous file is handed to
      # MediaGc.plan_generation! only after no projection still references
      # it. A kill before that leaves the old row ready and linked, so the
      # scheduler can resume the same checkpoint. The incoming row stores
      # the article digest in logical_digest, so Sequence can show the new
      # file before the public digest moves. Resource links move with the
      # digest, and only when that resource still lists this URL.
      #
      # The replacement MediaAttachment is saved before the link transaction.
      # If that transaction rolls back, the prepared row and its files are
      # destroyed. The next pass deletes an unlinked copy on the same status
      # with the same description, created at or after this checkpoint.
      class ReplaceGeneration
        EXTENSION_FOR_TYPE = {
          'image/jpeg' => 'jpg',
          'image/png' => 'png',
          'image/gif' => 'gif',
          'image/webp' => 'webp',
        }.freeze

        def self.call!(asset, result, resource, url_digest)
          new(asset, result, resource, url_digest).call!
        end

        def self.resume!(asset, resource, url_digest)
          new(asset, nil, resource, url_digest).resume!
        end

        def self.pending?(asset)
          return false unless asset&.ready?

          ExternalMediaAsset.exists?(url_digest: checkpoint_digest(asset.id))
        end

        def self.checkpoint_digest(asset_id)
          GenerationMap.incoming_digest(asset_id)
        end

        def initialize(asset, result, resource, url_digest)
          @asset = asset
          @result = result
          @resource = resource
          @url_digest = url_digest
        end

        def call!
          fresh = ExternalMediaAsset.find_by(id: @asset.id)
          return :missing unless fresh&.ready? && fresh.url_digest == @url_digest

          incoming = install!(fresh)
          return :missing if incoming.nil?

          continue!(fresh, incoming)
        end

        def resume!
          fresh = ExternalMediaAsset.find_by(id: @asset.id)
          incoming = fresh && ExternalMediaAsset.find_by(url_digest: self.class.checkpoint_digest(fresh.id))
          return :missing unless fresh&.ready? && fresh.url_digest == @url_digest && incoming

          continue!(fresh, incoming)
        end

        private

        def install!(fresh)
          created = nil
          ApplicationRecord.transaction do
            created = installed_row(ExternalMediaAsset.lock.find_by(id: fresh.id))
          end
          created
        rescue ActiveRecord::RecordNotUnique
          ExternalMediaAsset.find_by(url_digest: self.class.checkpoint_digest(fresh.id))
        end

        def installed_row(locked)
          return unless installable?(locked)

          found = ExternalMediaAsset.lock.find_by(url_digest: self.class.checkpoint_digest(locked.id))
          return reuse_checkpoint!(found) if found

          write_incoming!(locked)
        end

        def installable?(locked)
          locked&.ready? && locked.url_digest == @url_digest && @result&.body.present?
        end

        def reuse_checkpoint!(found)
          assign_file!(found) if replace_checkpoint?(found)
          found.update!(logical_digest: @url_digest) if found.logical_digest.blank?
          found
        end

        def replace_checkpoint?(found)
          @result.fingerprint != found.fingerprint && !referenced?(found)
        end

        def referenced?(asset)
          ExternalProjectionAttachment.exists?(external_media_asset_id: asset.id)
        end

        def write_incoming!(fresh)
          asset = ExternalMediaAsset.new(
            url_digest: self.class.checkpoint_digest(fresh.id),
            logical_digest: fresh.url_digest,
            kind: 'image',
            state: 'ready',
            generation: fresh.generation.to_i + 1
          )
          assign_file!(asset)
        end

        def assign_file!(asset)
          extension = AssetStore::EXTENSIONS.fetch(@result.type)
          Tempfile.create(['rss-generation', ".#{extension}"], binmode: true) do |file|
            file.write(@result.body)
            file.flush
            file.rewind
            asset.file = file
            asset.file_content_type = @result.content_type
            asset.assign_attributes(incoming_attributes)
            asset.save!
            asset
          end
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

        def continue!(fresh, incoming)
          @incoming = incoming
          moved = repoint_batch!(fresh)
          if projections_remain?(fresh.id)
            notify!(moved)
            return :partial
          end

          outcome = retire!(fresh, incoming)
          notify!(moved) if outcome == :partial
          outcome
        end

        def repoint_batch!(fresh)
          ids = ExternalProjectionAttachment.where(external_media_asset_id: fresh.id).order(:id).limit(Limits::MEDIA_REPOINT_BATCH).pluck(:id)
          ids.filter_map { |link_id| repoint_one!(link_id, fresh.id) }
        end

        def repoint_one!(link_id, old_id)
          previous = linked_attachment(link_id, old_id)
          return if previous == :absent
          return forget_link!(link_id) if previous.nil?

          reclaim_orphans!(previous)
          copied = copy_attachment(previous)
          commit_move!(link_id, old_id, previous.id, copied)
        end

        def linked_attachment(link_id, old_id)
          link = ExternalProjectionAttachment.find_by(id: link_id)
          return :absent if link.nil? || link.external_media_asset_id != old_id

          link.media_attachment
        end

        def forget_link!(link_id)
          ApplicationRecord.transaction do
            link = ExternalProjectionAttachment.lock.find_by(id: link_id)
            link&.destroy!
          end
          nil
        end

        # Paperclip writes files before the database commits. Create the
        # attachment first, then swing the link. A rollback or a raised
        # error destroys that row. A later pass collects a copy that was
        # left behind when the process stopped between those two steps.
        def commit_move!(link_id, old_id, previous_media_id, copied)
          result = nil
          ApplicationRecord.transaction(requires_new: true) do
            result = swing_link!(link_id, old_id, previous_media_id, copied)
            raise ActiveRecord::Rollback if result == :stale
          end
          release_prepared!(copied) if result == :stale
          result == :stale ? nil : result
        rescue StandardError
          release_prepared!(copied)
          raise
        end

        # Replace the projection row instead of updating it. The GC proof
        # records that row id while it still points at the previous file.
        # A later release accepts the proof only when that row is gone or
        # still names the previous file. Updating the row in place would
        # leave the previous file retained.
        def swing_link!(link_id, old_id, previous_media_id, copied)
          link = ExternalProjectionAttachment.lock.find_by(id: link_id)
          return :stale if link.nil? || link.external_media_asset_id != old_id || link.media_attachment_id != previous_media_id

          ExternalBridge::MediaGc.plan_replacement!(attachment_ids: [previous_media_id], asset_ids: [])
          marker_id = link.external_status_projection_id
          ExternalProjectionAttachment.create!(
            external_status_projection_id: marker_id,
            external_media_asset: @incoming,
            media_attachment: copied,
            position: link.position,
            kind: link.kind
          )
          link.destroy!
          ExternalBridge::MediaGc.schedule_release!(attachment_ids: [previous_media_id], asset_ids: [])
          marker_id
        end

        def reclaim_orphans!(previous)
          scope = MediaAttachment.where(status_id: previous.status_id, description: previous.description)
          scope = scope.where(file_content_type: @incoming.content_type) if @incoming.content_type.present?
          scope.where(MediaAttachment.arel_table[:created_at].gteq(@incoming.created_at)).find_each do |attachment|
            release_prepared!(attachment)
          end
        end

        def release_prepared!(attachment)
          return if attachment.nil?

          path = nil
          fresh = MediaAttachment.find_by(id: attachment.id)
          return if fresh.nil?
          return if ExternalProjectionAttachment.exists?(media_attachment_id: fresh.id)

          path = fresh.file.path
          fresh.destroy!
          delete_stored_files!(path)
        rescue ActiveRecord::ActiveRecordError
          delete_stored_files!(path)
          MediaAttachment.where(id: attachment.id).delete_all
        end

        def delete_stored_files!(path)
          return if path.blank?

          style_dir = File.dirname(path.to_s)
          directory = File.dirname(style_dir)
          return unless File.basename(style_dir) == 'original'

          marker = "#{File::SEPARATOR}media_attachments#{File::SEPARATOR}files#{File::SEPARATOR}"
          return unless directory.include?(marker)
          return unless File.directory?(directory)

          FileUtils.rm_rf(directory)
        end

        def copy_attachment(previous)
          extension = replacement_extension
          Tempfile.create(['rss-repoint', ".#{extension}"], binmode: true) do |file|
            file.write(replacement_body)
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

        def replacement_body
          return @result.body if use_result_body?

          @replacement_body ||= stored_body(@incoming)
        end

        def use_result_body?
          return false if @result.nil? || @result.body.blank?
          return true if @incoming.nil?

          @incoming.fingerprint == @result.fingerprint
        end

        def stored_body(asset)
          blob = nil
          Tempfile.create('rss-generation-read') do |file|
            asset.file.copy_to_local_file(:original, file.path)
            blob = File.binread(file.path)
          end
          blob
        end

        def replacement_extension
          return AssetStore::EXTENSIONS.fetch(@result.type) if use_result_body? && @result.type

          EXTENSION_FOR_TYPE.fetch(@incoming.content_type.to_s, 'bin')
        end

        def projections_remain?(asset_id)
          ExternalProjectionAttachment.exists?(external_media_asset_id: asset_id)
        end

        def retire!(fresh, incoming)
          markers = []
          outcome = :missing
          ApplicationRecord.transaction do
            outcome, markers = retire_locked(fresh, incoming)
          end
          notify!(markers)
          outcome
        rescue ActiveRecord::RecordNotFound
          :missing
        end

        def retire_locked(fresh, incoming)
          lock_pair(fresh.id, incoming.id)
          locked_old = ExternalMediaAsset.find(fresh.id)
          locked_new = ExternalMediaAsset.find(incoming.id)
          return [:replaced, marker_ids(locked_new)] if swapped?(locked_old, locked_new)
          return [:partial, []] if projections_remain?(locked_old.id)
          return [:missing, []] unless swappable?(locked_old, locked_new)

          swap!(locked_old, locked_new)
          [:replaced, marker_ids(locked_new)]
        end

        # Lower id first, same order as install!, so two passes cannot deadlock.
        def lock_pair(first_id, second_id)
          [first_id, second_id].sort.each { |asset_id| ExternalMediaAsset.lock.find(asset_id) }
        end

        def swapped?(locked_old, locked_new)
          locked_new.url_digest == @url_digest && locked_old.url_digest != @url_digest
        end

        def swappable?(locked_old, locked_new)
          locked_old.ready? && locked_old.url_digest == @url_digest && locked_new.url_digest == self.class.checkpoint_digest(locked_old.id)
        end

        def swap!(locked_old, locked_new)
          transfer_links!(locked_old, locked_new)
          now = Time.current
          locked_old.update_columns(url_digest: "superseded:#{locked_old.id}", state: 'failed', failure_code: 'superseded', updated_at: now)
          locked_new.update_columns(url_digest: @url_digest, updated_at: now)
          ExternalBridge::MediaGc.plan_generation!(locked_old.id)
          ExternalBridge::MediaGc.schedule_release!(attachment_ids: [], asset_ids: [locked_old.id])
        end

        def transfer_links!(old_asset, incoming)
          ids = ExternalMediaAssetResource.where(external_media_asset_id: old_asset.id).pluck(:external_resource_id)
          ids << @resource.id if @resource
          ExternalResource.where(id: ids.uniq).find_each do |record|
            next unless publishes?(record)

            AssetResource.link!(incoming.id, record.id)
          end
        end

        def publishes?(record)
          Array(record.media_candidates).any? { |row| matching_image?(row) }
        end

        def matching_image?(row)
          return false unless row.is_a?(Hash)

          row['kind'] == 'image' && row['url'].present? && MediaDigest.url_digest(row['url']) == @url_digest
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
