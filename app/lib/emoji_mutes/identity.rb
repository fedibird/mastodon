# frozen_string_literal: true

module EmojiMutes
  module Identity
    module_function

    def for_pair(name, custom_emoji)
      if custom_emoji&.local?
        { 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => custom_emoji.id.to_s }
      elsif custom_emoji&.remote?
        { 'kind' => 'custom', 'scope' => 'remote', 'domain' => normalize_domain(custom_emoji.domain), 'shortcode' => custom_emoji.shortcode }
      else
        { 'kind' => 'unicode', 'native' => name }
      end
    end

    def for_reaction(reaction)
      return nil if reaction.nil?

      return for_pair(reaction.name, nil) if reaction.custom_emoji_id.nil? && reaction.custom_emoji.nil?

      emoji = reaction.custom_emoji
      if emoji&.local?
        { 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => emoji.id.to_s }
      elsif emoji&.remote?
        { 'kind' => 'custom', 'scope' => 'remote', 'domain' => normalize_domain(emoji.domain), 'shortcode' => emoji.shortcode }
      elsif reaction.custom_emoji_id.nil?
        { 'kind' => 'unicode', 'native' => reaction.name }
      else
        { 'kind' => 'custom', 'scope' => 'unresolved', 'custom_emoji_id' => reaction.custom_emoji_id.to_s }
      end
    end

    def normalize_domain(domain)
      TagManager.instance.normalize_domain(domain)
    rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError, ArgumentError
      domain
    end
  end
end
