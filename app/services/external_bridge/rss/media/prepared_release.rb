# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Deletes one prepared subscriber file, and only the file named by an
      # external_media_repoint_stages row. The lease must have lapsed, no
      # projection link may point at the file, and the account must still
      # match. The status matches when it is unchanged, or when purge has
      # nullified it and that status row is gone. Paperclip destroy removes
      # the stored object. This class does not compute a storage path or
      # remove a directory itself.
      class PreparedRelease
        def self.release!(stage_id)
          new(stage_id).release!
        end

        def self.reclaim_expired!(projection_id:, asset_id:)
          scope = ExternalMediaRepointStage.where(
            external_status_projection_id: projection_id,
            external_media_asset_id: asset_id
          ).where(expired_lease)
          scope.pluck(:id).each { |stage_id| release!(stage_id) }
        end

        # Expired stages are not tied to the next repoint. Purge, an empty
        # subscriber list, and a stopped resource all leave the row in place.
        # The media GC pass calls this.
        def self.sweep_expired!(limit:)
          ids = ExternalMediaRepointStage.where(expired_lease).order(:id).limit(limit).pluck(:id)
          ids.each { |stage_id| release!(stage_id) }
          ids.size
        end

        def self.expired?
          ExternalMediaRepointStage.where(expired_lease).exists?
        end

        # Saves the copied attachment and its stage in one transaction. A
        # committed attachment from this path has a stage. A kill before that
        # commit leaves no row. Paperclip may already have written the bytes;
        # those bytes have no row, and this class does not search for them.
        def self.prepare!(asset_id:, projection_id:, account_id:, status_id:)
          ApplicationRecord.transaction(requires_new: true) do
            copied = yield
            stage = ExternalMediaRepointStage.create!(
              media_attachment_id: copied.id,
              external_media_asset_id: asset_id,
              external_status_projection_id: projection_id,
              account_id: account_id,
              status_id: status_id,
              lease_until: Limits::MEDIA_REPOINT_PREPARE_LEASE.from_now
            )
            [copied, stage]
          end
        end

        # The worker that created the stage is abandoning it. Expiring the
        # lease is the explicit hand-off. The same checks then run.
        def self.abandon!(stage)
          return if stage.nil?

          now = Time.current
          ExternalMediaRepointStage.where(id: stage.id).update_all(lease_until: now, updated_at: now)
          release!(stage.id)
        end

        def self.expired_lease
          ExternalMediaRepointStage.arel_table[:lease_until].lteq(Time.current)
        end
        private_class_method :expired_lease

        def initialize(stage_id)
          @stage_id = stage_id
        end

        def release!
          ApplicationRecord.transaction do
            stage = ExternalMediaRepointStage.lock.find_by(id: @stage_id)
            next if stage.nil? || stage.lease_until > Time.current

            attachment = MediaAttachment.lock.find_by(id: stage.media_attachment_id)
            if attachment.nil? || linked?(attachment)
              stage.destroy!
              next
            end
            next unless same_owner?(stage, attachment)

            attachment.destroy!
            stage.destroy!
          end
        rescue ActiveRecord::ActiveRecordError, Paperclip::Error
          Rails.logger.info("[ExternalBridge::RSS] media prepare release skipped stage_id=#{@stage_id}")
        end

        private

        def same_owner?(stage, attachment)
          return false unless attachment.account_id == stage.account_id
          return true if attachment.status_id == stage.status_id

          attachment.status_id.nil? && missing_status?(stage.status_id)
        end

        def missing_status?(status_id)
          !Status.unscoped.exists?(status_id)
        end

        def linked?(attachment)
          ExternalProjectionAttachment.exists?(media_attachment_id: attachment.id)
        end
      end
    end
  end
end
