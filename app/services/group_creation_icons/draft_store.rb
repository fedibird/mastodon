# frozen_string_literal: true

module GroupCreationIcons
  # Confirmation data lives in the signed session. The image bytes live in
  # private storage under a random key. The session never holds the bytes or
  # the visitor's filename.
  class DraftStore
    SESSION_KEY = 'group_creation_request_draft'

    def self.write!(session:, request:, inspection:)
      previous = session[SESSION_KEY]
      stored_key = nil
      stored_key = store_icon(inspection)
      session[SESSION_KEY] = payload(request, inspection, stored_key)
      release_replaced_icon(previous, stored_key)
      session[SESSION_KEY]
    rescue StandardError
      delete_quietly(stored_key)
      session.delete(SESSION_KEY)
      raise
    end

    def self.read(session, account:)
      raw = session[SESSION_KEY]
      return unless raw.is_a?(Hash)

      unless owns?(raw, account)
        discard!(session)
        return
      end

      expires = parse_time(raw['expires_at'])
      if expires.nil? || expires <= Time.current
        discard!(session)
        return
      end

      raw
    end

    def self.discard!(session)
      raw = session[SESSION_KEY]
      session.delete(SESSION_KEY)
      release_replaced_icon(raw, nil)
    end

    def self.clear!(session)
      session.delete(SESSION_KEY)
    end

    def self.store_icon(inspection)
      return if inspection.nil?

      key = nil
      key = GroupCreationIcons.generate_key
      Storage.resolve.write(key, StringIO.new(inspection.bytes), content_type: inspection.mime)
      key
    rescue StandardError
      delete_quietly(key)
      raise
    end

    def self.payload(request, inspection, stored_key)
      {
        'submission_token' => SecureRandom.uuid,
        'requester_account_id' => request.requester_account_id.to_s,
        'username' => request.username,
        'display_name' => request.display_name,
        'note' => request.note,
        'previous_request_id' => request.previous_request_id,
        'icon_storage_key' => stored_key,
        'icon_content_type' => inspection&.mime,
        'icon_byte_size' => inspection&.byte_size,
        'expires_at' => DRAFT_TTL.from_now.iso8601,
      }
    end

    def self.release_replaced_icon(previous, replacement_key)
      return unless previous.is_a?(Hash)

      key = previous['icon_storage_key']
      return if key.blank? || key == replacement_key
      return unless KEY_FORMAT.match?(key)
      return if GroupCreationRequest.exists?(icon_storage_key: key)

      delete_quietly(key)
    end

    def self.delete_quietly(key)
      return if key.blank?

      Storage.resolve.delete(key)
    rescue Error => e
      Rails.logger.error("Group creation icon draft cleanup failed error=#{e.class}")
    end

    def self.owns?(raw, account)
      owner_id = raw['requester_account_id'].to_s
      owner_id.present? && account&.id.to_s == owner_id
    end

    def self.parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    private_class_method :store_icon, :payload, :release_replaced_icon, :delete_quietly, :owns?, :parse_time
  end
end
