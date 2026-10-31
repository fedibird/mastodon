# frozen_string_literal: true

module GroupCreationIcons
  # Reads a staged original again and checks the bytes, the declared type,
  # and the image itself. A request with no icon is a no-op. This does not
  # write an Account avatar.
  class Revalidation
    Result = Struct.new(:bytes, :mime, :code, keyword_init: true) do
      def ok?
        code.nil?
      end
    end

    def self.call(request)
      new(request).call
    end

    def initialize(request)
      @request = request
    end

    def call
      return Result.new(bytes: nil, mime: nil, code: nil) if @request.icon_storage_key.blank?
      return Result.new(code: :icon_missing) if @request.icon_purged_at.present?

      bytes = Storage.resolve.read(@request.icon_storage_key)
      return Result.new(code: :icon_missing) if bytes.blank?
      return Result.new(code: :invalid_icon) unless bytes.bytesize == @request.icon_byte_size

      inspection = Inspector.call(StringIO.new(bytes))
      return Result.new(code: :invalid_icon) unless inspection.ok?
      return Result.new(code: :invalid_icon) unless inspection.mime == @request.icon_content_type
      return Result.new(code: :invalid_icon) unless inspection.byte_size == @request.icon_byte_size

      Result.new(bytes: bytes, mime: inspection.mime, code: nil)
    rescue NotFound
      Result.new(code: :icon_missing)
    rescue ConfigurationError
      Result.new(code: :storage_unavailable)
    end
  end
end
