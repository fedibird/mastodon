# frozen_string_literal: true

module ExternalBridge
  class MediaGc
    # Inserts pending intents. Attachment rows are inserted only when an
    # external_projection_attachments row still points at them. The same
    # statement writes an external_media_gc_proofs row; the database trigger
    # copies the link's attachment, projection, owner, and status. A compose
    # upload has no such link, so it is skipped. Callers must run this before
    # the purge DELETE or before the projection link is destroyed.
    #
    # Asset intents share a partial unique index while pending. A second
    # planner in that window inserts nothing. It still inserts an
    # external_media_gc_asset_rechecks row, which has no such index, so the
    # reference drop is not forgotten when the first intent later stays.
    class Plan
      COLUMNS = %i(
        target_type target_id reason state owner_account_id captured_status_id
        source_attachment_id captured_projection_id external_subscription_deletion_id
        available_at attempt_count created_at updated_at
      ).freeze

      def self.purge!(media, deletion_id: nil)
        captured = media.is_a?(Hash) ? media : {}
        new(
          attachment_ids: captured[:attachment_ids],
          asset_ids: captured[:asset_ids],
          attachment_reason: 'projection_purge',
          asset_reason: 'projection_purge',
          deletion_id: deletion_id
        ).insert!
      end

      def self.replacement!(attachment_ids:, asset_ids:)
        new(
          attachment_ids: attachment_ids,
          asset_ids: asset_ids,
          attachment_reason: 'attachment_replaced',
          asset_reason: 'asset_unreferenced',
          deletion_id: nil
        ).insert!
      end

      def self.generation!(asset_id)
        new(
          attachment_ids: [],
          asset_ids: [asset_id],
          attachment_reason: 'projection_purge',
          asset_reason: 'generation_replaced',
          deletion_id: nil
        ).insert!
      end

      # Called after a committed recheck finds no remaining link. A pending
      # row is left alone. A retained row does not occupy the unique index,
      # so this inserts the next look. No further recheck is written.
      def self.ensure_asset!(asset_id, reason:, deletion_id:)
        new(
          attachment_ids: [],
          asset_ids: [asset_id],
          attachment_reason: 'projection_purge',
          asset_reason: reason,
          deletion_id: deletion_id,
          record_recheck: false,
          immediate: true
        ).insert!
      end

      def initialize(attributes)
        @attachment_ids = MediaGc.normalize_ids(attributes[:attachment_ids])
        @asset_ids = MediaGc.normalize_ids(attributes[:asset_ids])
        @attachment_reason = attributes.fetch(:attachment_reason)
        @asset_reason = attributes.fetch(:asset_reason)
        @deletion_id = attributes[:deletion_id].to_i.nonzero?
        @record_recheck = attributes.fetch(:record_recheck, true)
        @immediate = attributes.fetch(:immediate, false)
        @now = Time.current
      end

      def insert!
        rows = attachment_rows + asset_rows
        return 0 if rows.empty?

        rows.each_slice(100) { |slice| insert_slice!(slice) }
        rows.size
      end

      private

      def attachment_rows
        return [] if @attachment_ids.empty?

        links = ExternalProjectionAttachment.where(media_attachment_id: @attachment_ids).includes(:media_attachment, :external_status_projection)
        links.filter_map { |link| attachment_row(link) }
      end

      def attachment_row(link)
        attachment = link.media_attachment
        projection = link.external_status_projection
        if attachment.nil? || projection.nil? || attachment.account_id.blank? || attachment.status_id.blank?
          log_skip('media_attachment', link.media_attachment_id)
          return nil
        end
        if attachment.account_id != projection.account_id || attachment.status_id != projection.status_id
          log_skip('media_attachment', attachment.id)
          return nil
        end

        insert_proof!(link)
        row(
          'media_attachment',
          attachment.id,
          @attachment_reason,
          [attachment.account_id, attachment.status_id, link.id, projection.id]
        )
      end

      def asset_rows
        return [] if @asset_ids.empty?

        ids = ExternalMediaAsset.where(id: @asset_ids).pluck(:id)
        insert_rechecks!(ids) if @record_recheck
        ids.map { |asset_id| row('external_media_asset', asset_id, @asset_reason, []) }
      end

      def insert_proof!(link)
        connection.execute(<<~SQL.squish)
          INSERT INTO external_media_gc_proofs (
            source_attachment_id, media_attachment_id, external_status_projection_id,
            account_id, status_id, created_at, updated_at
          )
          VALUES (
            #{link.id.to_i},
            #{link.media_attachment_id.to_i},
            #{link.external_status_projection_id.to_i},
            #{link.external_status_projection.account_id.to_i},
            #{link.external_status_projection.status_id.to_i},
            #{connection.quote(@now)},
            #{connection.quote(@now)}
          )
          ON CONFLICT (source_attachment_id) DO NOTHING
        SQL
      end

      def insert_rechecks!(asset_ids)
        return if asset_ids.empty?

        available = @now + MediaGc.grace
        values = asset_ids.map do |asset_id|
          "(#{asset_id.to_i}, #{connection.quote(@asset_reason)}, 'pending', #{connection.quote(@deletion_id)}, " \
            "#{connection.quote(available)}, #{connection.quote(@now)}, #{connection.quote(@now)})"
        end
        connection.execute(<<~SQL.squish)
          INSERT INTO external_media_gc_asset_rechecks (
            external_media_asset_id, reason, state, external_subscription_deletion_id,
            available_at, created_at, updated_at
          )
          VALUES #{values.join(',')}
        SQL
      end

      def row(target_type, target_id, reason, proof)
        owner_account_id, captured_status_id, source_attachment_id, captured_projection_id = proof
        {
          target_type: target_type,
          target_id: target_id,
          reason: reason,
          state: 'pending',
          owner_account_id: owner_account_id,
          captured_status_id: captured_status_id,
          source_attachment_id: source_attachment_id,
          captured_projection_id: captured_projection_id,
          external_subscription_deletion_id: @deletion_id,
          available_at: @immediate ? @now : @now + MediaGc.grace,
          attempt_count: 0,
          created_at: @now,
          updated_at: @now,
        }
      end

      def insert_slice!(slice)
        quoted = slice.map { |item| "(#{COLUMNS.map { |column| connection.quote(item[column]) }.join(',')})" }
        connection.execute(<<~SQL.squish)
          INSERT INTO external_media_gc_intents (#{COLUMNS.join(',')})
          VALUES #{quoted.join(',')}
          ON CONFLICT (target_type, target_id) WHERE state = 'pending' DO NOTHING
        SQL
      end

      def log_skip(target_type, target_id)
        Rails.logger.warn("[ExternalBridge::MediaGc] step=plan skipped=unproven target_type=#{target_type} target_id=#{target_id}")
      end

      def connection
        ExternalMediaGcIntent.connection
      end
    end
  end
end
