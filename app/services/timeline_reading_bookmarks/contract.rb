# frozen_string_literal: true

module TimelineReadingBookmarks
  class Contract
    SEARCH_KEYS = %w(
      q
      query
      text
      raw
      body
      spoiler_text
      spoiler
      content
      token
      access_token
      password
      secret
      caption
    ).freeze
    WINDOW_KEYS = %w(window items pages statuses status ids account).freeze
    TOP_LEVEL = %w(name source source_timeline_id context anchor lock_version).freeze
    IGNORED = %w(controller action format id reading_bookmark authenticity_token).freeze
    CONTROL = /[[:cntrl:]]/

    def self.build(raw, existing: nil)
      new(raw, existing).build
    end

    def self.stringify(value)
      case value
      when ActionController::Parameters
        stringify(value.to_unsafe_h)
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[key.to_s] = stringify(item)
        end
      when Array
        value.map { |item| stringify(item) }
      else
        value
      end
    end

    def self.timeline_id(source, context)
      data = stringify(context || {})
      case source.to_s
      when 'list' then "list:#{data['id']}"
      when 'group' then "group:#{data['id']}"
      when 'hashtag' then "hashtag:#{data['hashtag']}"
      when 'domain' then "domain:#{data['domain']}"
      else source.to_s
      end
    end

    def initialize(raw, existing)
      @raw = raw
      @existing = existing
    end

    def build
      data = self.class.stringify(@raw)
      raise Reject, 'search_or_content_not_accepted' if contains?(data, SEARCH_KEYS)
      raise Reject, 'window_not_accepted' if contains?(data, WINDOW_KEYS)

      payload = payload_from(data)
      source = source!(payload)
      context = context!(payload, source)
      assert_timeline_id!(payload, source, context)
      assert_lock_version!(payload)
      anchor = anchor!(payload)
      {
        name: name!(payload),
        source: source,
        context: context,
      }.merge(anchor)
    end

    private

    def payload_from(data)
      nested = data['reading_bookmark']
      if TOP_LEVEL.any? { |key| data.key?(key) }
        unknown_top_level!(data)
        data.slice(*TOP_LEVEL)
      elsif nested.is_a?(Hash)
        unknown_nested!(nested)
        nested.slice(*TOP_LEVEL)
      else
        {}
      end
    end

    def unknown_top_level!(data)
      data.each_key do |key|
        next if TOP_LEVEL.include?(key) || IGNORED.include?(key)

        raise Reject, 'unsupported_field'
      end
    end

    def unknown_nested!(nested)
      nested.each_key do |key|
        raise Reject, 'unsupported_field' unless TOP_LEVEL.include?(key)
      end
    end

    def contains?(value, keys)
      case value
      when Hash
        value.any? { |key, item| keys.include?(key.to_s) || contains?(item, keys) }
      when Array
        value.any? { |item| contains?(item, keys) }
      else
        false
      end
    end

    def source!(payload)
      source = if payload.key?('source')
                 payload['source'].to_s
               elsif @existing
                 @existing.source
               end
      raise Reject, 'invalid_source' unless TimelineReadingBookmark::SOURCES.include?(source)

      source
    end

    def context!(payload, source)
      if payload.key?('context')
        Context.normalize!(source, payload['context'])
      elsif @existing && source == @existing.source
        self.class.stringify(@existing.context)
      else
        Context.normalize!(source, {})
      end
    end

    def assert_timeline_id!(payload, source, context)
      return unless payload.key?('source_timeline_id')

      given = normalize_timeline_id(source, payload['source_timeline_id'].to_s)
      raise Reject, 'source_mismatch' if given != self.class.timeline_id(source, context)
    end

    def normalize_timeline_id(source, given)
      return given unless source == 'domain' && given.start_with?('domain:')

      host = TagManager.instance.normalize_domain(given.delete_prefix('domain:'))
      host.present? ? "domain:#{host}" : given
    rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError
      given
    end

    def assert_lock_version!(payload)
      return unless @existing
      raise Reject, 'lock_version_required' unless payload.key?('lock_version')

      value = payload['lock_version']
      text = value.to_s
      raise Reject.new('conflict', 409) unless text.match?(/\A\d+\z/)
      raise Reject.new('conflict', 409) if Integer(text, 10) != @existing.lock_version
    end

    def anchor!(payload)
      if payload.key?('anchor')
        Anchor.normalize!(payload['anchor'])
      elsif @existing
        stored_anchor
      else
        raise Reject, 'invalid_anchor'
      end
    end

    def stored_anchor
      {
        anchor_version: @existing.anchor_version,
        anchor_status_id: @existing.anchor_status_id,
        display_row_id: @existing.display_row_id,
        offset_px: @existing.offset_px,
        alignment: @existing.alignment,
        captured_at: @existing.captured_at,
      }
    end

    def name!(payload)
      unless payload.key?('name')
        raise Reject, 'invalid_name' unless @existing

        return @existing.name
      end

      text = payload['name'].to_s
      raise Reject, 'invalid_name' if text.match?(CONTROL)

      stripped = text.strip
      raise Reject, 'invalid_name' if stripped.empty? || stripped.length > TimelineReadingBookmark::NAME_MAX_LENGTH

      stripped
    end
  end
end
