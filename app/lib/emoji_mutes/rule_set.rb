# frozen_string_literal: true

module EmojiMutes
  # One user's rules, loaded once per request. Matching never issues another
  # SELECT. Remote cache rows are not created here.
  class RuleSet
    class << self
      def for_user(user)
        return empty if user.nil?

        store = EmojiMutes::Store.rule_sets ||= {}
        store[user.id] ||= load(user.id)
      end

      def empty
        @empty ||= new([].freeze, 0).freeze
      end

      def load(user_id)
        rows = EmojiMute.where(user_id: user_id).to_a
        revision = EmojiMuteCollection.where(user_id: user_id).pick(:revision) || 0
        new(rows, revision)
      end
    end

    attr_reader :revision

    def initialize(rows, revision)
      @rows = rows
      @revision = revision.to_i
      @by_local = {}
      @by_remote = {}
      @unicode = []
      rows.each do |row|
        case row.kind
        when 'local'
          @by_local[row.custom_emoji_id.to_s] = row
        when 'remote'
          @by_remote[[row.domain, row.shortcode]] = row
        else
          @unicode << row
        end
      end
    end

    def hide_any?
      @rows.any?(&:hide_reactions)
    end

    def rejects_reaction?(identity)
      rule = match(identity)
      rule.present? && rule.reject_reactions_to_own_posts
    end

    def hides_identity?(identity)
      rule = match(identity)
      rule.present? && rule.hide_reactions
    end

    def hides_unicode_name?(name)
      @unicode.any? { |row| row.hide_reactions && UnicodeMatch.match?(row.native, name) }
    end

    def hide_unicode_variants
      @unicode.select(&:hide_reactions).flat_map { |row| UnicodeMatch.variants(row.native) }.uniq
    end

    def hide_local_ids
      @by_local.each_with_object([]) do |(id, row), ids|
        ids << id.to_i if row.hide_reactions
      end
    end

    def hide_remote_pairs
      @by_remote.each_with_object([]) do |((domain, shortcode), row), pairs|
        next unless row.hide_reactions

        domain_variants(domain).each { |variant| pairs << [variant, shortcode] }
      end
    end

    def match(identity)
      return nil unless identity.is_a?(Hash)

      kind = identity['kind'] || identity[:kind]
      case kind
      when 'unicode'
        native = identity['native'] || identity[:native]
        @unicode.find { |row| UnicodeMatch.match?(row.native, native) }
      when 'custom'
        scope = identity['scope'] || identity[:scope]
        if scope == 'local'
          id = (identity['custom_emoji_id'] || identity[:custom_emoji_id]).to_s
          @by_local[id]
        elsif scope == 'remote'
          domain = identity['domain'] || identity[:domain]
          shortcode = identity['shortcode'] || identity[:shortcode]
          @by_remote[[domain, shortcode]]
        end
      end
    end

    private

    def domain_variants(domain)
      unicode = Addressable::IDNA.to_unicode(domain)
      [domain, unicode].uniq
    rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError, ArgumentError
      [domain]
    end
  end
end
