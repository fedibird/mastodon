# frozen_string_literal: true

require 'zlib'

module ExternalBridge
  module RSS
    # Bounded read of one feed response body.
    #
    # "Received" bytes are the HTTP message body after transfer framing has
    # been removed and before Content-Encoding is reversed. "Inflated" bytes
    # are what remains after that reversal (identical to the received bytes
    # when the body is not compressed). Both caps are checked before a chunk
    # is appended. A chunk that does not fit is not truncated into a
    # successful body.
    #
    # HTTP.rb auto_inflate must not already have wrapped the stream. Feed
    # requests pass a client without that feature; inflating twice would
    # hide the encoded size and then corrupt the bytes.
    #
    # One deflate input of N bytes produces at most N * 1032 output bytes.
    # The longest match is 258 bytes and the shortest code for that match is
    # 2 bits (258 / (2/8) = 1032). INPUT_CHUNK is therefore inflated into a
    # temporary string of at most INPUT_CHUNK * 1032 bytes, and a larger
    # result is rejected instead of appended. Ruby's Zlib::Inflate#inflate
    # grows its own buffer for the whole call, so the input is sliced to
    # INPUT_CHUNK before that call. The 1032 ratio was checked against zlib
    # in this repository's Ruby 3.2: a 1024-byte slice of a gzip of NUL
    # bytes returned 1_056_768 bytes and no slice returned more.
    class BodyReader
      INPUT_CHUNK = 1024
      MAX_EXPANSION = 1032
      MAX_INFLATE_OUTPUT = INPUT_CHUNK * MAX_EXPANSION
      # Same window as HTTP.rb 5.2.0's Inflater. It accepts a gzip or zlib
      # wrapper and does not accept raw deflate. A second inflater with a
      # different window is not tried.
      WINDOW_BITS = 32 + Zlib::MAX_WBITS
      INFLATED_ENCODINGS = %w(gzip x-gzip deflate).freeze

      def self.read!(response, received_limit:, inflated_limit:)
        new(response, received_limit, inflated_limit).read!
      end

      def initialize(response, received_limit, inflated_limit)
        @response = response
        @received_limit = integer_limit(received_limit)
        @inflated_limit = integer_limit(inflated_limit)
      end

      def read!
        raise Error, :fetch_failed if http_already_inflated?

        reject_declared_length!
        case body_encoding
        when :identity then read_identity
        when :inflate then read_deflate
        else raise Error, :fetch_failed
        end
      end

      private

      def integer_limit(value)
        raise ArgumentError, 'body limit must be a non-negative integer' unless value.is_a?(Integer) && !value.negative?

        value
      end

      def http_already_inflated?
        return false unless defined?(HTTP::Response::Inflater)

        body = @response.body if @response.respond_to?(:body)
        stream = body.instance_variable_get(:@stream) if body.respond_to?(:instance_variable_get)
        stream.is_a?(HTTP::Response::Inflater)
      end

      # Content-Length is the encoded size when it is a non-negative integer.
      # Chunked responses and invalid values report nil here and are limited
      # by the bytes actually pulled from the stream. A short Content-Length
      # is not a promise that unread trailer bytes will be fetched: the HTTP
      # parser stops at the declared length.
      def reject_declared_length!
        length = declared_length
        return if length.nil? || length <= @received_limit

        raise Error, :oversized_feed
      end

      def declared_length
        length = @response.content_length
        length.is_a?(Integer) && !length.negative? ? length : nil
      end

      def body_encoding
        tokens = encoding_tokens
        return :identity if tokens.empty? || tokens == ['identity']
        return :inflate if tokens.one? && INFLATED_ENCODINGS.include?(tokens.first)

        :rejected
      end

      def encoding_tokens
        header_values('Content-Encoding').flat_map { |value| value.to_s.split(',') }.map { |token| token.strip.downcase }.reject(&:empty?)
      end

      def header_values(name)
        headers = @response.headers
        return [] unless headers.respond_to?(:get)

        Array(headers.get(name))
      end

      def read_identity
        buffer = binary_buffer
        received = 0
        each_input_slice do |slice|
          ensure_room!(received, slice.bytesize, @received_limit)
          ensure_room!(buffer.bytesize, slice.bytesize, @inflated_limit)
          buffer << slice
          received += slice.bytesize
        end
        buffer
      end

      def read_deflate
        buffer = binary_buffer
        received = 0
        inflater = Zlib::Inflate.new(WINDOW_BITS)
        begin
          each_input_slice do |slice|
            ensure_room!(received, slice.bytesize, @received_limit)
            received += slice.bytesize
            append_output!(buffer, inflate_slice(inflater, slice))
          end
          append_output!(buffer, finish_stream(inflater))
          buffer
        ensure
          close_stream(inflater)
        end
      end

      def each_input_slice
        loop do
          chunk = next_chunk
          break if chunk.nil?
          next if chunk.empty?

          offset = 0
          while offset < chunk.bytesize
            slice = chunk.byteslice(offset, INPUT_CHUNK).b
            offset += slice.bytesize
            yield slice
          end
        end
      end

      def next_chunk
        chunk = @response.readpartial(INPUT_CHUNK)
        return nil if chunk.nil?

        chunk.b
      end

      def inflate_slice(inflater, slice)
        inflater.inflate(slice)
      rescue Zlib::Error
        raise Error, :fetch_failed
      end

      def finish_stream(inflater)
        return ''.b if inflater.finished?

        inflater.finish
      rescue Zlib::Error
        raise Error, :fetch_failed
      end

      def append_output!(buffer, produced)
        # Whitespace is payload. blank? would drop a body that is only spaces.
        return if produced.nil? || produced.empty? # rubocop:disable Rails/Blank

        bytes = produced.b
        unless bytes.bytesize <= MAX_INFLATE_OUTPUT && room?(buffer.bytesize, bytes.bytesize, @inflated_limit)
          bytes.clear
          raise Error, :oversized_feed
        end

        buffer << bytes
      end

      def ensure_room!(used, addition, limit)
        raise Error, :oversized_feed unless room?(used, addition, limit)
      end

      def room?(used, addition, limit)
        addition <= limit - used
      end

      def close_stream(inflater)
        inflater.close
      rescue Zlib::Error
        nil
      end

      def binary_buffer
        String.new(encoding: Encoding::BINARY)
      end
    end
  end
end
