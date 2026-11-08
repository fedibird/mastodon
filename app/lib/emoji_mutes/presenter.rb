# frozen_string_literal: true

module EmojiMutes
  # Read model for saved rules. Looking up a cached emoji does not fetch or
  # copy one. Image URLs are omitted so a collapsed settings list cannot
  # treat this payload as something to draw.
  class Presenter
    def initialize(mutes)
      @mutes = Array(mutes)
      ids = @mutes.select { |mute| mute.kind == 'local' }.map(&:custom_emoji_id)
      @local = ids.empty? ? {} : CustomEmoji.where(id: ids).index_by(&:id)
      @remote = load_remote
    end

    def list(revision)
      {
        'revision' => revision.to_s,
        'effect_application' => effect_application,
        'emoji_mutes' => @mutes.map { |mute| item(mute) },
      }
    end

    def one(mute, revision)
      {
        'revision' => revision.to_s,
        'effect_application' => effect_application,
        'emoji_mute' => item(mute),
      }
    end

    private

    def item(mute)
      {
        'id' => mute.id.to_s,
        'revision' => mute.revision.to_s,
        'emoji' => reference_for(mute),
        'effects' => mute.effects,
        'replacement' => mute.replacement,
        'detail' => detail_for(mute),
      }
    end

    def reference_for(mute)
      emoji = mute.kind == 'local' ? @local[mute.custom_emoji_id] : nil
      reference = mute.reference
      reference['shortcode'] = emoji.shortcode if emoji
      reference
    end

    def detail_for(mute)
      case mute.kind
      when 'unicode'
        catalog = PersonalEmojiSets::UnicodeCatalog.find(mute.native)
        if catalog
          { 'state' => 'resolved', 'kind' => 'unicode', 'emoji_id' => catalog[:id] }
        else
          { 'state' => 'unavailable', 'kind' => 'unicode' }
        end
      when 'local'
        emoji = @local[mute.custom_emoji_id]
        if emoji
          { 'state' => 'resolved', 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => emoji.id.to_s, 'shortcode' => emoji.shortcode, 'disabled' => emoji.disabled? }
        else
          { 'state' => 'unavailable', 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => mute.custom_emoji_id.to_s, 'shortcode' => mute.shortcode }
        end
      else
        emoji = remote_for(mute)
        if emoji
          { 'state' => 'fetched', 'kind' => 'custom', 'scope' => 'remote', 'domain' => mute.domain, 'shortcode' => mute.shortcode, 'cache_id' => emoji.id.to_s }
        else
          { 'state' => 'unfetched', 'kind' => 'custom', 'scope' => 'remote', 'domain' => mute.domain, 'shortcode' => mute.shortcode }
        end
      end
    end

    def load_remote
      pairs = @mutes.select { |mute| mute.kind == 'remote' }
      return {} if pairs.empty?

      domains = pairs.flat_map { |mute| domain_variants(mute.domain) }.uniq
      shortcodes = pairs.map(&:shortcode).uniq
      CustomEmoji.remote.where(shortcode: shortcodes, domain: domains).to_a
    end

    def remote_for(mute)
      variants = domain_variants(mute.domain)
      matches = @remote.select { |emoji| emoji.shortcode == mute.shortcode && variants.include?(emoji.domain) }
      matches.find { |emoji| Identity.normalize_domain(emoji.domain) == mute.domain } || matches.min_by(&:id)
    end

    def domain_variants(domain)
      [domain, Addressable::IDNA.to_unicode(domain)].uniq
    rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError, ArgumentError
      [domain]
    end

    def effect_application
      {
        'applied' => EmojiMute::APPLIED_EFFECTS,
        'stored_only' => EmojiMute::STORED_ONLY_EFFECTS,
      }
    end
  end
end
