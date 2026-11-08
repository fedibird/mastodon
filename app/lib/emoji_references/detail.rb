# frozen_string_literal: true

# Display data for one resolved emoji. Image URLs live only here. They are
# not part of the stable reference.
class EmojiReferences::Detail
  include RoutingHelper

  def unicode(native, emoji)
    {
      state: 'resolved',
      kind: 'unicode',
      native: native,
      emoji_id: emoji.fetch(:id),
      label: emoji.fetch(:label),
      image: {
        src: full_asset_url("/emoji/#{emoji.fetch(:filename)}.svg"),
        alt: native,
        title: emoji.fetch(:label),
        width: 36,
        height: 36,
      },
      search: emoji.fetch(:search),
    }
  end

  def custom(record)
    payload = {
      state: 'fetched',
      kind: 'custom',
      scope: record.local? ? 'local' : 'remote',
      shortcode: record.shortcode,
      emoji: ActiveModelSerializers::SerializableResource.new(record, serializer: REST::CustomEmojiDetailSerializer).as_json,
    }
    if record.local?
      payload[:custom_emoji_id] = record.id.to_s
    else
      payload[:domain] = record.domain
      payload[:cache_id] = record.id.to_s
    end
    payload
  end

  def unfetched(domain, shortcode)
    {
      state: 'unfetched',
      kind: 'custom',
      scope: 'remote',
      domain: domain,
      shortcode: shortcode,
    }
  end
end
