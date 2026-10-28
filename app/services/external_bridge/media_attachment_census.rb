# frozen_string_literal: true

module ExternalBridge
  # Read-only comparison of the attachment rows a status actually has.
  #
  # StatusesHelper#media_summary counts every media_attachments row, including
  # posters and rows that are no longer in the display order. The WebUI and
  # the REST media_attachments list use ordered_media_attachments, which drops
  # projection rows whose kind is poster. This census reports ids and lifecycle
  # states so those two sets can be compared. It does not print status text,
  # remote URLs, or signed query strings, and it does not delete or update rows.
  module MediaAttachmentCensus
    module_function

    def call(status_or_id)
      status = status_or_id.is_a?(Status) ? status_or_id : Status.find(status_or_id)
      raw_ids = status.media_attachments.order(:id).pluck(:id)
      display_ids = status.ordered_media_attachments.map(&:id)
      projection_rows = projection_attachments(status)
      linked_ids = projection_rows.map { |row| row[:media_attachment_id] }
      undisplayed_ids = raw_ids - display_ids
      unlinked_ids = raw_ids - linked_ids

      {
        status_id: status.id,
        raw_attachment_ids: raw_ids,
        display_attachment_ids: display_ids,
        summary_counts: summary_counts(status),
        projection_attachments: projection_rows,
        raw_not_displayed_ids: undisplayed_ids,
        raw_without_projection_row_ids: unlinked_ids,
        lifecycle: lifecycle_for(undisplayed_ids | unlinked_ids),
      }
    end

    def summary_counts(status)
      counts = { image: 0, video: 0, audio: 0 }

      status.media_attachments.each do |media|
        if media.video?
          counts[:video] += 1
        elsif media.audio?
          counts[:audio] += 1
        else
          counts[:image] += 1
        end
      end

      counts
    end

    def projection_attachments(status)
      projection = status.external_status_projection
      return [] if projection.nil?

      projection.external_projection_attachments.order(:position, :id).map do |row|
        {
          media_attachment_id: row.media_attachment_id,
          kind: row.kind,
          position: row.position,
        }
      end
    end

    def lifecycle_for(attachment_ids)
      ids = Array(attachment_ids).uniq
      return [] if ids.empty?

      stages = ExternalMediaRepointStage.where(media_attachment_id: ids).order(:id).group_by(&:media_attachment_id)
      intents = ExternalMediaGcIntent.where(target_type: 'media_attachment', target_id: ids).order(:id).group_by(&:target_id)

      ids.map do |attachment_id|
        {
          media_attachment_id: attachment_id,
          repoint_stages: Array(stages[attachment_id]).map { |stage| { id: stage.id, state: stage.state } },
          gc_intents: Array(intents[attachment_id]).map { |intent| { id: intent.id, state: intent.state, reason: intent.reason } },
        }
      end
    end
  end
end
