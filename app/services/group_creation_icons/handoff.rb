# frozen_string_literal: true

module GroupCreationIcons
  # P2 reads the staged original and copies it onto Account#avatar.
  # P1 never calls that copy. release_after_copy! runs only after the
  # approval transaction has committed and the public avatar exists.
  module Handoff
    module_function

    def staged_original(request)
      return if request.icon_storage_key.blank? || request.icon_purged_at.present?

      bytes = Storage.resolve.read(request.icon_storage_key)
      file = Tempfile.new(['group-creation-icon', Delivery.extension(request.icon_content_type)])
      file.binmode
      file.write(bytes)
      file.rewind
      file
    end

    def release_after_copy!(request)
      request.with_lock do
        raise Error, 'icon release requires an approved request' unless request.approved?
        next if request.icon_storage_key.blank? || request.icon_purged_at.present?

        Storage.resolve.delete(request.icon_storage_key)
        request.update!(icon_purged_at: Time.current)
      end
    end
  end
end
