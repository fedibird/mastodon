# frozen_string_literal: true

# Display availability for a page of rules. A missing row stays addressable.
# This does not fetch a remote URL or insert a local copy.
class EmojiMutes::Availability
  def initialize(mutes)
    @mutes = Array(mutes)
    @local = CustomEmoji.local.where(id: local_ids).index_by(&:id)
    @remote = remote_rows
  end

  def state_for(mute)
    case mute.kind
    when 'unicode'
      PersonalEmojiSets::UnicodeCatalog.find(mute.native) ? 'available' : 'unavailable'
    when 'local'
      @local[mute.custom_emoji_id] ? 'available' : 'unavailable'
    else
      remote_for(mute) ? 'available' : 'unfetched'
    end
  end

  def cache_id_for(mute)
    return unless mute.kind == 'remote'

    remote_for(mute)&.id&.to_s
  end

  def shortcode_for(mute)
    return mute.shortcode unless mute.kind == 'local'

    @local[mute.custom_emoji_id]&.shortcode || mute.shortcode
  end

  private

  def local_ids
    @mutes.select { |mute| mute.kind == 'local' }.map(&:custom_emoji_id)
  end

  def remote_rows
    pairs = @mutes.select { |mute| mute.kind == 'remote' }
    return {} if pairs.empty?

    shortcodes = pairs.map(&:shortcode).uniq
    CustomEmoji.remote.where(shortcode: shortcodes).each_with_object({}) do |emoji, memo|
      pairs.each do |mute|
        next unless mute.shortcode == emoji.shortcode && EmojiMutes::Domain.same?(mute.domain, emoji.domain)

        memo[mute.id] ||= emoji
      end
    end
  end

  def remote_for(mute)
    @remote[mute.id]
  end
end
