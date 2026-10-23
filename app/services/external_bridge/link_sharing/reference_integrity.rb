# frozen_string_literal: true

module ExternalBridge
  module LinkSharing
    # A reference note is an ordinary Status of the User, so the User can edit
    # it after it is created. The boost only trusts a note that is still the
    # link-only note E4-A wrote.
    #
    # The identity is a digest of the stored text, taken when the mapping was
    # inserted, plus a fixed shape: no spoiler, no sensitive mark, no media,
    # poll, quote, reference, or reply, and the visibility of the mapping. The
    # digest is not recomputed from the current source title, so a later source
    # title change does not make an untouched note unusable. A note that was
    # edited to add text, a warning, an attachment, or anything else in the
    # shape list is refused. Reverting the edit makes it usable again.
    module ReferenceIntegrity
      module_function

      def digest(text)
        Digest::SHA256.hexdigest(text.to_s)
      end

      def verify!(mapping, status)
        raise Error, :reference_broken if unusable?(mapping, status)
        raise Error, :reference_modified unless text_unchanged?(mapping, status) && shape_unchanged?(mapping, status)

        true
      end

      def unusable?(mapping, status)
        status.nil? ||
          status.deleted_at.present? ||
          status.external_projection == true ||
          status.account_id != mapping.account_id ||
          status.reblog_of_id.present?
      end

      def text_unchanged?(mapping, status)
        expected = mapping.reference_digest.presence || legacy_digest(mapping)
        expected.present? && ActiveSupport::SecurityUtils.secure_compare(expected, digest(status.text))
      end

      # Rows written before the digest column existed. Only the allowlist text
      # derived from the current source is accepted for them.
      def legacy_digest(mapping)
        source = mapping.external_status_projection&.external_resource&.external_source
        return nil if source.nil?

        digest(NoteText.compose(source: source, canonical_url: mapping.canonical_url))
      end

      def shape_unchanged?(mapping, status)
        status.visibility == mapping.visibility &&
          status.spoiler_text.to_s.empty? &&
          !status.sensitive &&
          !status.reply &&
          status.in_reply_to_id.nil? &&
          status.quote_id.nil? &&
          !status.ap_page? &&
          !MediaAttachment.where(status_id: status.id).exists? &&
          !StatusReference.where(status_id: status.id).exists? &&
          !Poll.where(status_id: status.id).exists?
      end
    end
  end
end
