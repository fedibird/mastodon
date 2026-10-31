# frozen_string_literal: true

module GroupCreationIcons
  # Copies an approved request's private original onto Account#avatar, then
  # deletes the private original. The approval transaction has already
  # committed. A failed copy does not create another group. A second run
  # does not write the avatar again once the source digest and the avatar
  # file name are both stored.
  class Copy
    MAX_ATTEMPTS = 8

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_sym
        super(@code.to_s)
      end
    end

    def self.call(request)
      new(request).call
    end

    def initialize(request)
      @request = request
    end

    def call
      @request.with_lock { copy_bytes! }
      mark_copied!
      release!
    rescue Error => e
      record_failure!(e.code)
      raise
    rescue StandardError
      record_failure!(:copy_failed)
      raise
    end

    private

    def copy_bytes!
      return unless @request.approved?
      return if @request.icon_storage_key.blank? || @request.icon_purged_at.present?
      return if @request.icon_handoff_copied_at.present?
      return if exhausted?

      result = Revalidation.call(@request)
      raise Error, result.code unless result.ok?

      digest = Digest::SHA256.hexdigest(result.bytes)
      return if same_avatar?(digest)

      write_avatar!(result.bytes, result.mime, digest)
    end

    def exhausted?
      return false if @request.icon_handoff_attempts.to_i < MAX_ATTEMPTS

      Rails.logger.warn("Group creation icon handoff stopped request_id=#{@request.id} attempts=#{@request.icon_handoff_attempts} error=#{@request.icon_handoff_error}")
      true
    end

    def same_avatar?(digest)
      @request.icon_handoff_source_digest == digest && @request.group_account.avatar_file_name.present?
    end

    def write_avatar!(bytes, mime, digest)
      file = tempfile_for(bytes, mime)
      group = @request.group_account
      group.avatar = file
      group.save!
      raise Error, :copy_failed if group.avatar_file_name.blank? || group.avatar_remote_url.present?

      @request.update!(
        icon_handoff_source_digest: digest,
        icon_handoff_error: nil,
        icon_handoff_failed_at: nil
      )
    rescue StandardError
      discard_avatar_files(group)
      raise
    ensure
      file&.close!
    end

    def tempfile_for(bytes, mime)
      file = Tempfile.new(['group-creation-icon', Delivery.extension(mime)])
      file.binmode
      file.write(bytes)
      file.rewind
      file
    end

    def discard_avatar_files(group)
      return if group.nil?

      group.avatar.destroy
    rescue StandardError => e
      Rails.logger.error("Group icon avatar cleanup failed account_id=#{group.id} error=#{e.class}")
    end

    def mark_copied!
      @request.with_lock do
        return if @request.icon_handoff_copied_at.present?
        return if @request.icon_handoff_source_digest.blank?
        return if @request.group_account&.avatar_file_name.blank?

        @request.update!(
          icon_handoff_copied_at: Time.current,
          icon_handoff_error: nil,
          icon_handoff_failed_at: nil
        )
      end
    end

    def release!
      @request.reload
      return if @request.icon_handoff_copied_at.blank? || @request.icon_storage_key.blank?

      Handoff.release_after_copy!(@request) if @request.icon_purged_at.blank?
      @request.reload
      return if @request.icon_purged_at.blank?
      return if @request.icon_handoff_error.blank? && @request.icon_handoff_failed_at.blank?

      @request.update!(icon_handoff_error: nil, icon_handoff_failed_at: nil)
    rescue StandardError => e
      Rails.logger.error("Group creation icon release failed request_id=#{@request.id} error=#{e.class}")
      raise Error, :release_failed
    end

    def record_failure!(code)
      @request.reload
      @request.update!(
        icon_handoff_attempts: @request.icon_handoff_attempts.to_i + 1,
        icon_handoff_error: code.to_s,
        icon_handoff_failed_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("Group creation icon handoff record failed request_id=#{@request.id} error=#{e.class}")
    end
  end
end
