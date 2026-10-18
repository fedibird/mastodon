# frozen_string_literal: true

module TimelineReadingBookmarks
  class Anchor
    KEYS = %w(version status_id display_row_id offset_px alignment captured_at).freeze
    DISPLAY_ROW = /\A(?:[1-9]\d{0,18}|f-[1-9]\d{0,18})\z/
    FEATURED = /\Af-([1-9]\d{0,18})\z/

    def self.normalize!(raw)
      new(raw).normalize!
    end

    def initialize(raw)
      @raw = raw
    end

    def normalize!
      raise Reject, 'invalid_anchor' unless @raw.is_a?(Hash)

      data = Contract.stringify(@raw)
      raise Reject, 'invalid_anchor' if (data.keys - KEYS).any?
      raise Reject, 'invalid_anchor' unless version_one?(data['version'])

      status_id, display_row_id = pair_ids(data)
      {
        anchor_version: 1,
        anchor_status_id: status_id,
        display_row_id: display_row_id,
        offset_px: offset!(data['offset_px']),
        alignment: alignment!(data['alignment']),
        captured_at: captured_at!(data['captured_at']),
      }
    end

    private

    def version_one?(value)
      [1, '1'].include?(value)
    end

    def pair_ids(data)
      status_id = data.key?('status_id') && !data['status_id'].nil? ? read_status!(data['status_id']) : nil
      display_row_id = display_row!(data['display_row_id'])
      implied = implied_status(display_row_id)
      raise Reject, 'invalid_anchor' if status_id && implied && status_id != implied

      status_id ||= implied
      raise Reject, 'invalid_anchor' if status_id.nil? || TimelineSeek::StatusId.parse(status_id).nil?

      [status_id, display_row_id]
    end

    def read_status!(value)
      status_id = decimal_id(value)
      raise Reject, 'invalid_anchor' if status_id.nil?

      status_id
    end

    def decimal_id(value)
      return nil if value.nil?

      text = value.to_s
      return nil unless text.match?(/\A[1-9]\d{0,18}\z/)
      return nil if TimelineSeek::StatusId.parse(text).nil?

      text
    end

    def display_row!(value)
      return nil if value.nil?
      raise Reject, 'invalid_anchor' unless value.is_a?(String) && value.match?(DISPLAY_ROW)

      value
    end

    def implied_status(display_row_id)
      return nil if display_row_id.nil?
      return display_row_id if display_row_id.match?(/\A[1-9]\d{0,18}\z/)

      FEATURED.match(display_row_id)&.[](1)
    end

    def offset!(value)
      text = value.to_s
      raise Reject, 'invalid_anchor' unless text.match?(/\A-?\d+\z/)

      number = Integer(text, 10)
      raise Reject, 'invalid_anchor' unless TimelineReadingBookmark::OFFSET_RANGE.cover?(number)

      number
    end

    def alignment!(value)
      text = value.to_s
      raise Reject, 'invalid_anchor' unless TimelineReadingBookmark::ALIGNMENTS.include?(text)

      text
    end

    def captured_at!(value)
      return nil if value.nil? || value == ''

      text = value.to_s
      if text.match?(/\A\d{4}-\d{2}-\d{2}T/) && !text.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/)
        raise Reject, 'invalid_anchor'
      end

      Time.iso8601(text).utc
    rescue ArgumentError
      raise Reject, 'invalid_anchor'
    end
  end
end
