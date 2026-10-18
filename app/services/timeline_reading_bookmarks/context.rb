# frozen_string_literal: true

module TimelineReadingBookmarks
  class Context
    BOOLEAN_TRUE = [true, 1, '1', 'true', 'TRUE'].freeze
    BOOLEAN_FALSE = [false, 0, '0', 'false', 'FALSE'].freeze
    TAG_MAX = 64
    TAG_LIST_MAX = 16

    def self.normalize!(source, raw)
      new(source, raw).normalize!
    end

    def initialize(source, raw)
      @source = source
      @raw = raw
    end

    def normalize!
      raise Reject, 'invalid_context' unless @raw.is_a?(Hash)

      data = Contract.stringify(@raw)
      case @source
      when 'home', 'limited' then home!(data)
      when 'list' then id_only!(data, 'list_id')
      when 'group' then group!(data)
      when 'hashtag' then hashtag!(data)
      when 'public' then flags!(data, %w(remote only_media without_media without_bot))
      when 'domain' then domain!(data)
      when 'personal' then flags!(data, %w(only_media without_media))
      else raise Reject, 'invalid_source'
      end
    end

    private

    def home!(data)
      visibilities = data.delete('visibilities')
      raise Reject, 'invalid_context' if data.any?

      list = visibilities!(visibilities)
      list.empty? ? {} : { 'visibilities' => list }
    end

    def id_only!(data, alias_key)
      primary = data.delete('id')
      aliased = data.delete(alias_key)
      raise Reject, 'invalid_context' if data.any?

      id = one_id!(primary, aliased)
      { 'id' => id }
    end

    def group!(data)
      primary = data.delete('id')
      aliased = data.delete('group_id')
      flags = take_flags!(data, %w(only_media without_media))
      has_tagged = data.key?('tagged')
      tagged = data.delete('tagged')
      raise Reject, 'invalid_context' if data.any?

      result = { 'id' => one_id!(primary, aliased) }.merge(flags)
      result['tagged'] = tag!(tagged) if has_tagged
      result
    end

    def hashtag!(data)
      name = data.delete('hashtag')
      lists = {
        'any' => tag_list!(data.delete('any')),
        'all' => tag_list!(data.delete('all')),
        'none' => tag_list!(data.delete('none')),
      }
      raise Reject, 'invalid_context' if data.any?

      result = { 'hashtag' => tag!(name) }
      lists.each do |key, values|
        result[key] = values if values.any?
      end
      result
    end

    def domain!(data)
      raw_domain = data.delete('domain')
      local = data.delete('local')
      raise Reject, 'invalid_context' if [true, 'true', '1', 1].include?(local)

      flags = take_flags!(data, %w(only_media without_media without_bot))
      raise Reject, 'invalid_context' if data.any?

      { 'domain' => domain_name!(raw_domain) }.merge(flags)
    end

    def flags!(data, keys)
      flags = take_flags!(data, keys)
      raise Reject, 'invalid_context' if data.any?

      flags
    end

    def take_flags!(data, keys)
      keys.index_with do |key|
        boolean!(data.delete(key))
      end
    end

    def boolean!(value)
      return false if value.nil?
      return true if BOOLEAN_TRUE.include?(value)
      return false if BOOLEAN_FALSE.include?(value)

      raise Reject, 'invalid_context'
    end

    def visibilities!(value)
      return [] if value.nil?
      raise Reject, 'invalid_context' unless value.is_a?(Array)
      raise Reject, 'invalid_context' if value.length > Status.visibilities.size

      names = value.map(&:to_s)
      known = Status.visibilities.keys
      raise Reject, 'invalid_context' if names.any? { |name| known.exclude?(name) }

      names.uniq.sort
    end

    def one_id!(primary, aliased)
      first = read_id!(primary)
      second = read_id!(aliased)
      raise Reject, 'invalid_context' if first.nil? && second.nil?
      raise Reject, 'source_mismatch' if first && second && first != second

      first || second
    end

    def read_id!(value)
      return nil if value.nil?

      id = decimal_id(value)
      raise Reject, 'invalid_context' if id.nil?

      id
    end

    def decimal_id(value)
      return nil if value.nil?

      text = value.to_s
      return nil unless text.match?(/\A[1-9]\d{0,18}\z/)
      return nil if TimelineSeek::StatusId.parse(text).nil?

      text
    end

    def tag_list!(value)
      return [] if value.nil?
      raise Reject, 'invalid_context' unless value.is_a?(Array)
      raise Reject, 'invalid_context' if value.length > TAG_LIST_MAX

      value.map { |item| tag!(item) }
    end

    def tag!(value)
      text = value.to_s.strip.delete_prefix('#')
      raise Reject, 'invalid_context' if text.empty? || text.length > TAG_MAX
      raise Reject, 'invalid_context' if text.match?(/[[:cntrl:]\s\/?#]/)

      text
    end

    def domain_name!(value)
      normalized = TagManager.instance.normalize_domain(value.to_s.strip)
      raise Reject, 'invalid_context' if normalized.blank? || normalized.length > 253
      raise Reject, 'invalid_context' if normalized.match?(/[[:cntrl:]\s]/)

      normalized
    rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError
      raise Reject, 'invalid_context'
    end
  end
end
