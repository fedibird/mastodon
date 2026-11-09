# frozen_string_literal: true

module EmojiMutes
  # Adds identity parts to the unfiltered grouped cache. Parts are not a
  # second public grouping. The name group, its representative, and its
  # account_ids stay the compatibility payload. A missing custom emoji keeps
  # the identity previously stored for that id so a cache-row delete does not
  # retarget the part. This runs inside the status_stats row lock.
  class CacheParts
    include RoutingHelper

    def self.attach!(status, groups, previous_cache: nil)
      new(status, previous_cache).attach!(groups)
    end

    def self.parts_for_rows(rows)
      new(nil, nil).parts_for(rows)
    end

    def initialize(status, previous_cache)
      @status = status
      @previous = index_previous(previous_cache)
    end

    def attach!(groups)
      names = groups.map { |group| group['name'] }
      return groups if names.empty?

      rows = @status.emoji_reactions.includes(:custom_emoji).where(name: names).order(:created_at).to_a
      by_name = rows.group_by(&:name)
      groups.each do |group|
        group['parts'] = parts_for(by_name[group['name']] || [])
      end
      groups
    end

    def parts_for(rows)
      ordered = []
      index = {}
      rows.each do |reaction|
        identity = identity_for(reaction)
        key = identity_key(identity)
        part = index[key]
        unless part
          part = { 'identity' => identity, 'account_ids' => [] }
          copy_display!(part, reaction)
          index[key] = part
          ordered << part
        end
        part['account_ids'] << reaction.account_id.to_s
      end
      ordered.each { |part| part['count'] = part['account_ids'].size }
      ordered
    end

    private

    def identity_for(reaction)
      saved = @previous[reaction.custom_emoji_id.to_s] if reaction.custom_emoji_id
      return saved['identity'] if reaction.custom_emoji.nil? && saved && saved['identity']

      Identity.for_reaction(reaction)
    end

    def copy_display!(part, reaction)
      saved = reaction.custom_emoji_id ? @previous[reaction.custom_emoji_id.to_s] : nil
      emoji = reaction.custom_emoji
      if emoji
        part['custom_emoji_id'] = emoji.id.to_s
        part['shortcode'] = emoji.shortcode
        part['url'] = full_asset_url(emoji.image.url)
        part['static_url'] = full_asset_url(emoji.image.url(:static))
        part['domain'] = emoji.domain
        part['width'] = emoji.width if emoji.width
        part['height'] = emoji.height if emoji.height
        part['alternate_name'] = emoji.alternate_name if emoji.alternate_name.present?
        part['ruby'] = emoji.ruby if emoji.ruby.present?
      elsif saved
        %w(custom_emoji_id shortcode url static_url domain width height alternate_name ruby).each do |key|
          part[key] = saved[key] if saved.key?(key)
        end
      end
    end

    def index_previous(cache)
      groups = ReactionProjection.parse(cache)
      groups.flat_map { |group| Array(group['parts']) }.each_with_object({}) do |part, index|
        id = part['custom_emoji_id'] || part.dig('identity', 'custom_emoji_id')
        index[id.to_s] = part if id
      end
    end

    def identity_key(identity)
      case identity['scope']
      when 'local'
        "local:#{identity['custom_emoji_id']}"
      when 'remote'
        "remote:#{identity['domain']}:#{identity['shortcode']}"
      when 'unresolved'
        "unresolved:#{identity['custom_emoji_id']}"
      else
        "unicode:#{identity['native']}"
      end
    end
  end
end
