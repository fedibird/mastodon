# frozen_string_literal: true

module PostDrafts
  # P0 input.media is id, order, description, and focus. Those fields are
  # stored in the snapshot so the content hash stays stable. They are not
  # copied onto the media record.
  module MediaFields
    private

    def media(value)
      return [] if value.nil?
      fail!('invalid_type', 'input.media') unless value.is_a?(Array)
      fail!('too_many', 'input.media') if value.size > attachment_limit

      items = value.each_with_index.map { |item, index| media_item(item, index) }
      fail!('duplicate_media', 'input.media') if items.map { |item| item['id'] }.uniq.size != items.size

      items.sort_by { |item| [item['order'], item['id']] }
    end

    def attachment_limit
      configured = Setting.attachments_max.to_i
      ceiling = MediaAttachment::ATTACHMENTS_LIMIT
      return ceiling if configured <= 0

      [configured, ceiling].min
    end

    def media_item(item, index)
      key = "input.media[#{index}]"
      require_object!(item, key)
      reject_unknown!(item, %w(id order description focus), key)
      id = reference(item['id'], "#{key}.id")
      fail!('invalid_reference', "#{key}.id") if id.nil?

      {
        'id' => id,
        'order' => media_order(item['order'], index, "#{key}.order"),
        'description' => media_description(item['description'], "#{key}.description"),
        'focus' => media_focus(item['focus'], "#{key}.focus"),
      }
    end

    def media_order(value, index, key)
      return index if value.nil?
      fail!('invalid_type', key) unless value.is_a?(Integer)
      fail!('invalid_format', key) unless value.between?(0, 10_000)

      value
    end

    def media_description(value, key)
      return '' if value.nil?
      fail!('invalid_type', key) unless value.is_a?(String)
      fail!('too_long', key) if value.length > MediaAttachment::MAX_DESCRIPTION_LENGTH
      fail!('invalid_format', key) if value.gsub(/[\n\r\t]/, '').match?(/[[:cntrl:]]/)

      value
    end

    def media_focus(value, key)
      return { 'x' => 0, 'y' => 0 } if value.nil?

      require_object!(value, key)
      reject_unknown!(value, %w(x y), key)
      {
        'x' => focus_axis(value['x'], "#{key}.x"),
        'y' => focus_axis(value['y'], "#{key}.y"),
      }
    end

    def focus_axis(value, key)
      numeric = value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
      fail!('invalid_type', key) unless numeric
      fail!('invalid_format', key) unless value.between?(-1, 1)

      value
    end
  end
end
