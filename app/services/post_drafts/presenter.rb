# frozen_string_literal: true

module PostDrafts
  class Presenter
    PREVIEW_CHARS = 140

    def initialize(viewer = nil)
      @viewer = viewer
    end

    def one(draft)
      view = MediaView.new(draft, @viewer)
      identity(draft).merge(
        media_retained: view.retained?,
        media_restore: view.restore,
        media: view.documents,
        payload: draft.payload
      )
    end

    def preview(draft)
      input = draft.payload.is_a?(Hash) ? (draft.payload['input'] || {}) : {}
      surface = input['surface'].is_a?(Hash) ? input['surface'] : {}
      text = input['text'].to_s

      identity(draft).merge(
        media_retained: MediaView.retained?(draft),
        media_count: draft.post_draft_media_attachments.size,
        preview: {
          text: text[0, PREVIEW_CHARS],
          text_truncated: text.length > PREVIEW_CHARS,
          spoiler_text: input['spoiler_text'].to_s[0, PREVIEW_CHARS],
          privacy: input['privacy'],
          surface_kind: surface['kind'],
          surface_key: surface['key'],
          in_reply_to: input['in_reply_to_id'].present?,
          quote: input['quote_id'].present?,
        }
      )
    end

    private

    def identity(draft)
      {
        draft_id: draft.id.to_s,
        client_uuid: draft.client_uuid,
        revision: draft.revision,
        schema_version: draft.schema_version,
        state: draft.state,
        created_at: draft.created_at.iso8601,
        updated_at: draft.updated_at.iso8601,
      }
    end
  end
end
