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
        return failure(:corrupt) unless complete_image?(bytes, mime, file.path)

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

    def complete_image?(bytes, mime, path)
      return png_complete?(bytes) && imagemagick_decodes?(path) if mime == 'image/png'
      return ico_complete?(bytes) if mime == 'image/vnd.microsoft.icon'

      imagemagick_decodes?(path)
    end

    def png_complete?(bytes)
      signature = "\x89PNG\r\n\x1a\n".b
      return false unless bytes.start_with?(signature)

      offset = signature.bytesize
      saw_ihdr = false
      saw_idat = false
      while offset + 12 <= bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1('N')
        return false if length.negative? || offset + 12 + length > bytes.bytesize

        type = bytes.byteslice(offset + 4, 4)
        chunk = bytes.byteslice(offset + 4, 4 + length)
        crc = bytes.byteslice(offset + 8 + length, 4).unpack1('N')
        return false unless Zlib.crc32(chunk) == crc

        case type
        when 'IHDR'
          return false if saw_ihdr || length != 13

          saw_ihdr = true
        when 'IDAT'
          return false unless saw_ihdr

          saw_idat = true
        when 'IEND'
          return false unless length.zero? && saw_ihdr && saw_idat

          return offset + 12 == bytes.bytesize
        end
        offset += 12 + length
      end
      false
    end

    def ico_complete?(bytes)
      return false if bytes.bytesize < 22

      reserved, type, count = bytes.byteslice(0, 6).unpack('vvv')
      reserved.zero? && type == 1 && count.positive? && bytes.bytesize >= 6 + (count * 16)
    end

    def imagemagick_decodes?(path)
      _output, status = Open3.capture2e(
        'identify', '-limit', 'memory', '256MB', '-limit', 'map', '512MB',
        '-limit', 'width', MAX_DIMENSION.to_s, '-limit', 'height', MAX_DIMENSION.to_s,
        '-limit', 'time', '10', path
      )
      status.success?
    rescue Errno::ENOENT
      false
    end

    def failure(error)
      Result.new(error: error)
    end
  end
end
