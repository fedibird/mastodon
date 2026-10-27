# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Deletes one prepared subscriber file, and only the file named by an
      # external_media_repoint_stages row. The lease must have lapsed, no
      # projection link may point at the file, and the account and status
      # must still match the stage. Paperclip destroy removes the stored
      # object. This class does not compute a storage path or remove a
      # directory itself.
      class PreparedRelease
        def self.release!(stage_id)
          new(stage_id).release!
        end

        def self.reclaim_expired!(projection_id:, asset_id:)
          scope = ExternalMediaRepointStage.where(
            external_status_projection_id: projection_id,
            external_media_asset_id: asset_id
          ).where(ExternalMediaRepointStage.arel_table[:lease_until].lteq(Time.current))
          scope.pluck(:id).each { |stage_id| release!(stage_id) }
        end

        # The worker that created the stage is abandoning it. Expiring the
        # lease is the explicit hand-off. The same checks then run.
        def self.abandon!(stage)
          return if stage.nil?

          now = Time.current
          ExternalMediaRepointStage.where(id: stage.id).update_all(lease_until: now, updated_at: now)
          release!(stage.id)
        end

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
          attachment.account_id == stage.account_id && attachment.status_id == stage.status_id
        end

        def linked?(attachment)
          ExternalProjectionAttachment.exists?(media_attachment_id: attachment.id)
        end
      end
    end
  end
end
