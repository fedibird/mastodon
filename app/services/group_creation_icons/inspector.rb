# frozen_string_literal: true

module GroupCreationIcons
  # Trusts the bytes, not the uploaded filename or Content-Type.
  # HEIC, HEIF, AVIF, and SVG stay rejected with the avatar allowlist.
  class Inspector
    Result = Struct.new(:mime, :byte_size, :bytes, :error, keyword_init: true) do
      def ok?
        error.nil?
      end
    end

    def self.call(upload)
      new(upload).call
    end

    def initialize(upload)
      @upload = upload
    end

    def call
      io = readable_io
      return failure(:unreadable) if io.nil?

      bytes = limited_bytes(io)
      return failure(:empty) if bytes.blank?
      return failure(:too_large) if bytes.bytesize >= MAX_BYTES

      detect(bytes)
    end

    private

    def readable_io
      return @upload.tempfile if @upload.respond_to?(:tempfile) && @upload.tempfile
      return @upload if @upload.respond_to?(:read) && !@upload.is_a?(String)

      nil
    end

    def limited_bytes(io)
      io.rewind if io.respond_to?(:rewind)
      bytes = io.read(MAX_BYTES + 1)
      io.rewind if io.respond_to?(:rewind)
      bytes.to_s.b
    end

    def detect(bytes)
      Tempfile.create(['group-creation-icon']) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        mime = mime_for(file.path)
        return failure(:type_not_allowed) if mime.nil?
        return failure(:spoofed) unless marcel_agrees?(file.path, mime)

        dimension_problem = dimension_error(file.path)
        return failure(dimension_problem) if dimension_problem

        Result.new(mime: mime, byte_size: bytes.bytesize, bytes: bytes)
      end
    end

    def mime_for(path)
      FAST_IMAGE_TYPES[FastImage.type(path)]
    end

    def marcel_agrees?(path, mime)
      detected = Marcel::MimeType.for(Pathname.new(path))
      MIME_EQUIVALENTS.fetch(mime).include?(detected)
    end

    def dimension_error(path)
      size = FastImage.size(path)
      return :corrupt unless size.is_a?(Array) && size.compact.size == 2

      width, height = size
      return :corrupt if width <= 0 || height <= 0
      return :too_many_pixels if width > MAX_DIMENSION || height > MAX_DIMENSION || (width * height) > MAX_PIXELS

      nil
    end

    def failure(error)
      Result.new(error: error)
    end
  end
end
