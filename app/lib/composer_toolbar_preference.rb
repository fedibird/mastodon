# frozen_string_literal: true

# Per-user order and placement for the composer footer controls.
#
# This is intentionally outside UserPreferences::Reader / WriteContract.
# Those keys are the Mastodon-compatible preferences API. A toolbar layout
# is a WebUI setting: the Rails preferences form writes it, and the WebUI
# reads the normalized list from initial state. Arbitrary strings are rejected
# on write. Stored garbage, older JSON, and unknown ids normalize to a safe
# layout on read.
class ComposerToolbarPreference
  class Invalid < ArgumentError; end

  VAR = 'composer_toolbar'
  VERSION = 'v1'
  IDS = %w(
    posting_account
    media
    cw
    language
    datetime
    searchability
    poll
  ).freeze
  PLACEMENTS = %w(visible menu hidden).freeze
  DEFAULT_PLACEMENTS = {
    'posting_account' => 'visible',
    'media' => 'visible',
    'cw' => 'visible',
    'language' => 'visible',
    'datetime' => 'menu',
    'searchability' => 'menu',
    'poll' => 'menu',
  }.freeze
  ICONS = {
    'posting_account' => 'user',
    'media' => 'paperclip',
    'cw' => 'warning',
    'language' => 'globe',
    'datetime' => 'calendar',
    'searchability' => 'search',
    'poll' => 'tasks',
  }.freeze

  class << self
    def default_items
      IDS.map { |id| item(id, DEFAULT_PLACEMENTS.fetch(id)) }
    end

    def dump(items)
      "#{VERSION}|#{normalize(items).map { |entry| "#{entry['id']}:#{entry['placement']}" }.join('|')}"
    end

    def effective(user)
      return default_items if user.nil?

      normalize(user.settings[VAR])
    end

    def normalize(raw)
      order = []
      placements = {}

      each_token(raw) do |id, placement|
        next unless IDS.include?(id)
        next if placements.key?(id)

        placements[id] = PLACEMENTS.include?(placement) ? placement : DEFAULT_PLACEMENTS.fetch(id)
        order << id
      end

      IDS.each do |id|
        next if placements.key?(id)

        placements[id] = DEFAULT_PLACEMENTS.fetch(id)
        order << id
      end

      order.map { |id| item(id, placements[id]) }
    end

    # The settings form submits one canonical string. Anything else is refused
    # and is not written.
    def accept!(raw)
      text = raw.is_a?(String) ? raw.strip : nil
      raise Invalid, 'invalid_type' if text.blank?

      parts = text.split('|')
      raise Invalid, 'invalid_value' unless parts.shift == VERSION
      raise Invalid, 'invalid_value' unless parts.size == IDS.size

      seen = {}
      items = parts.map do |part|
        id, placement = part.split(':', 2)
        raise Invalid, 'invalid_value' unless IDS.include?(id) && PLACEMENTS.include?(placement) && !seen[id]

        seen[id] = true
        item(id, placement)
      end
      raise Invalid, 'invalid_value' unless seen.keys.sort == IDS.sort

      items
    end

    def write!(user, raw)
      items = accept!(raw)
      user.settings[VAR] = dump(items)
      items
    end

    private

    def item(id, placement)
      { 'id' => id, 'placement' => placement }
    end

    def each_token(raw, &block)
      return unless block

      case raw
      when String
        parse_string(raw, &block)
      when Array
        raw.each do |entry|
          next unless entry.is_a?(Hash)

          block.call(entry['id'].to_s, entry['placement'].to_s)
        end
      when Hash
        list = raw['items'] || raw[:items]
        each_token(list, &block) if list
      end
    end

    def parse_string(text, &block)
      return unless block

      stripped = text.to_s.strip
      if stripped.start_with?("#{VERSION}|")
        stripped.delete_prefix("#{VERSION}|").split('|').each do |part|
          id, placement = part.split(':', 2)
          block.call(id.to_s, placement.to_s)
        end
        return
      end

      parsed = parse_json(stripped)
      each_token(parsed, &block) if parsed
    end

    def parse_json(text)
      return nil unless text.start_with?('{', '[')

      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
  end
end
