# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Icon
      # Structural validation of a Windows icon (.ico) file.
      #
      # An ICO is the one format that is stored and served without being
      # re-encoded (ImageMagick's ICO coder is not available everywhere), so
      # a header that merely looks like an ICO is not enough. Every directory
      # entry must point at a payload that is itself well formed, the payloads
      # must not overlap, and no bytes may be left over that no entry
      # describes. Anything else is rejected and the next candidate is tried.
      #
      # Accepted payloads, which is what browsers and icon tools produce:
      # - PNG: signature, IHDR matching the directory entry, every chunk length
      #   in bounds with a correct CRC, IEND as the last chunk, and no bytes
      #   after it. Color type and bit depth must be valid for PNG.
      # - BMP/DIB (BITMAPINFOHEADER, 40 bytes, uncompressed or BITFIELDS):
      #   dimensions that agree with the entry, a legal bit count, and enough
      #   bytes for the palette, the pixel rows and the AND mask.
      #
      # Up to MAX_ENTRIES images are accepted. The largest decides the size
      # that is checked against the icon limits. The pixel data of a PNG is
      # not inflated here; the browser decodes it in its own sandbox, and the
      # file is bounded by Limits::ICON_MAX_BYTES.
      module IcoValidator
        MAX_ENTRIES = 16
        HEADER_BYTES = 6
        ENTRY_BYTES = 16
        PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
        DIB_HEADER_BYTES = 40
        DIB_BIT_COUNTS = [1, 4, 8, 16, 24, 32].freeze
        PNG_COLOR_DEPTHS = { 0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16] }.freeze

        Entry = Struct.new(:width, :height, :bit_count, :bytes, :offset)

        module_function

        # Returns [width, height] of the largest image, or raises
        # ExternalBridge::RSS::Error with :icon_invalid_ico.
        def validate!(body)
          data = body.to_s.b
          entries = read_directory!(data)
          check_layout!(entries, data.bytesize)
          entries.each { |entry| check_payload!(entry, data.byteslice(entry.offset, entry.bytes)) }

          largest = entries.max_by { |entry| [entry.width * entry.height, entry.width] }
          [largest.width, largest.height]
        end

        def invalid!
          raise Error, :icon_invalid_ico
        end

        def read_directory!(data)
          invalid! if data.bytesize < HEADER_BYTES
          reserved, type, count = data.unpack('vvv')
          invalid! unless reserved.zero? && type == 1 && count.between?(1, MAX_ENTRIES)
          invalid! if data.bytesize < HEADER_BYTES + (count * ENTRY_BYTES)

          Array.new(count) do |index|
            width, height, _colors, reserved_byte, _planes, bit_count, size, offset =
              data.byteslice(HEADER_BYTES + (index * ENTRY_BYTES), ENTRY_BYTES).unpack('CCCCvvVV')
            invalid! unless reserved_byte.zero?

            Entry.new(width.zero? ? 256 : width, height.zero? ? 256 : height, bit_count, size, offset)
          end
        end

        def check_layout!(entries, total)
          first_payload = HEADER_BYTES + (entries.size * ENTRY_BYTES)
          ranges = entries.map do |entry|
            invalid! if entry.bytes <= 0 || entry.offset < first_payload
            invalid! if entry.offset + entry.bytes > total

            [entry.offset, entry.offset + entry.bytes]
          end

          ranges.sort.each_cons(2) { |left, right| invalid! if left[1] > right[0] }
          invalid! unless ranges.map(&:last).max == total
        end

        def check_payload!(entry, payload)
          if payload.start_with?(PNG_SIGNATURE)
            check_png!(entry, payload)
          else
            check_dib!(entry, payload)
          end
        end

        def check_png!(entry, payload)
          position = PNG_SIGNATURE.bytesize
          first = true
          finished = false

          while position < payload.bytesize
            invalid! if finished || position + 12 > payload.bytesize

            length = payload.byteslice(position, 4).unpack1('N')
            type = payload.byteslice(position + 4, 4)
            invalid! unless type.match?(/\A[A-Za-z]{4}\z/n)
            invalid! if length > payload.bytesize - position - 12

            data = payload.byteslice(position + 8, length)
            crc = payload.byteslice(position + 8 + length, 4).unpack1('N')
            invalid! unless Zlib.crc32(type + data) == crc

            if first
              invalid! unless type == 'IHDR' && length == 13

              check_ihdr!(entry, data)
              first = false
            end
            finished = true if type == 'IEND'
            invalid! if type == 'IEND' && length != 0

            position += 12 + length
          end

          invalid! unless finished && position == payload.bytesize
        end

        def check_ihdr!(entry, data)
          width, height, depth, color, compression, filter, interlace = data.unpack('NNCCCCC')
          invalid! unless width == entry.width && height == entry.height
          invalid! unless PNG_COLOR_DEPTHS.fetch(color, []).include?(depth)
          invalid! unless compression.zero? && filter.zero? && [0, 1].include?(interlace)
        end

        def check_dib!(entry, payload)
          invalid! if payload.bytesize < DIB_HEADER_BYTES

          header_size, width, signed_height, planes, bit_count, compression, _image_size, _xppm, _yppm, colors_used, _important =
            payload.unpack('VVlvvVVllVV')
          invalid! unless header_size == DIB_HEADER_BYTES && planes == 1
          invalid! unless DIB_BIT_COUNTS.include?(bit_count)
          invalid! unless width == entry.width

          # The height of an icon bitmap covers the pixels and the AND mask.
          has_mask = signed_height == entry.height * 2
          invalid! unless has_mask || signed_height == entry.height

          invalid! unless dib_compression_ok?(compression, bit_count)

          needed = DIB_HEADER_BYTES + dib_extra_bytes(compression, bit_count, colors_used)
          needed += dib_row_bytes(width, bit_count) * entry.height
          needed += dib_row_bytes(width, 1) * entry.height if has_mask
          invalid! if payload.bytesize < needed
        end

        def dib_compression_ok?(compression, bit_count)
          compression.zero? || (compression == 3 && [16, 32].include?(bit_count))
        end

        def dib_extra_bytes(compression, bit_count, colors_used)
          return 12 if compression == 3

          palette_entries = colors_used
          palette_entries = 1 << bit_count if bit_count <= 8 && colors_used.zero?
          invalid! if palette_entries > 256

          palette_entries * 4
        end

        def dib_row_bytes(width, bit_count)
          (((width * bit_count) + 31) / 32) * 4
        end
      end
    end
  end
end
