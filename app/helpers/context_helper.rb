# frozen_string_literal: true

module ContextHelper
  NAMED_CONTEXT_MAP = {
    activitystreams: 'https://www.w3.org/ns/activitystreams',
    security: 'https://w3id.org/security/v1',
  }.freeze

  CONTEXT_EXTENSION_MAP = {
    manually_approves_followers: { 'manuallyApprovesFollowers' => 'as:manuallyApprovesFollowers' },
    sensitive: { 'sensitive' => 'as:sensitive' },
    hashtag: { 'Hashtag' => 'as:Hashtag' },
    moved_to: { 'movedTo' => { '@id' => 'as:movedTo', '@type' => '@id' } },
    also_known_as: { 'alsoKnownAs' => { '@id' => 'as:alsoKnownAs', '@type' => '@id' } },
    emoji: { 'toot' => 'http://joinmastodon.org/ns#', 'Emoji' => 'toot:Emoji' },
    featured: { 'toot' => 'http://joinmastodon.org/ns#', 'featured' => { '@id' => 'toot:featured', '@type' => '@id' }, 'featuredTags' => { '@id' => 'toot:featuredTags', '@type' => '@id' } },
    property_value: { 'schema' => 'http://schema.org#', 'PropertyValue' => 'schema:PropertyValue', 'value' => 'schema:value' },
    atom_uri: { 'ostatus' => 'http://ostatus.org#', 'atomUri' => 'ostatus:atomUri' },
    conversation: { 'ostatus' => 'http://ostatus.org#', 'inReplyToAtomUri' => 'ostatus:inReplyToAtomUri', 'conversation' => 'ostatus:conversation' },
    focal_point: { 'toot' => 'http://joinmastodon.org/ns#', 'focalPoint' => { '@container' => '@list', '@id' => 'toot:focalPoint' } },
    identity_proof: { 'toot' => 'http://joinmastodon.org/ns#', 'IdentityProof' => 'toot:IdentityProof' },
    blurhash: { 'toot' => 'http://joinmastodon.org/ns#', 'blurhash' => 'toot:blurhash' },
    discoverable: { 'toot' => 'http://joinmastodon.org/ns#', 'discoverable' => 'toot:discoverable' },
    indexable: { 'toot' => 'http://joinmastodon.org/ns#', 'indexable' => 'toot:indexable' },
    voters_count: { 'toot' => 'http://joinmastodon.org/ns#', 'votersCount' => 'toot:votersCount' },
    olm: {
      'toot' => 'http://joinmastodon.org/ns#', 'Device' => 'toot:Device', 'Ed25519Signature' => 'toot:Ed25519Signature', 'Ed25519Key' => 'toot:Ed25519Key', 'Curve25519Key' => 'toot:Curve25519Key', 'EncryptedMessage' => 'toot:EncryptedMessage', 'publicKeyBase64' => 'toot:publicKeyBase64', 'deviceId' => 'toot:deviceId',
      'claim' => { '@type' => '@id', '@id' => 'toot:claim' },
      'fingerprintKey' => { '@type' => '@id', '@id' => 'toot:fingerprintKey' },
      'identityKey' => { '@type' => '@id', '@id' => 'toot:identityKey' },
      'devices' => { '@type' => '@id', '@id' => 'toot:devices' },
      'messageFranking' => 'toot:messageFranking', 'messageType' => 'toot:messageType', 'cipherText' => 'toot:cipherText'
    },
    suspended: { 'toot' => 'http://joinmastodon.org/ns#', 'suspended' => 'toot:suspended' },
    quote_uri: { 'fedibird' => 'http://fedibird.com/ns#', 'quoteUri' => 'fedibird:quoteUri' },
    expiry: { 'fedibird' => 'http://fedibird.com/ns#', 'expiry' => 'fedibird:expiry' },
    other_setting: { 'fedibird' => 'http://fedibird.com/ns#', 'otherSetting' => 'fedibird:otherSetting' },
    references: { 'fedibird' => 'http://fedibird.com/ns#', 'references' => { '@id' => "fedibird:references", '@type' => '@id' } },
    emoji_reactions: { 'fedibird' => 'http://fedibird.com/ns#', 'emojiReactions' => { '@id' => "fedibird:emojiReactions", '@type' => '@id' } },
    searchable_by: { 'fedibird' => 'http://fedibird.com/ns#', 'searchableBy' => { '@id' => "fedibird:searchableBy", '@type' => '@id' } },
    thumbhash: { 'fedibird' => 'http://fedibird.com/ns#', 'thumbhash' => 'fedibird:thumbhash' },
    category: { 'schema' => 'http://schema.org#', 'category' => 'schema:category' },
    keywords: { 'schema' => 'http://schema.org#', 'keywords' => 'schema:keywords' },
    license: { 'schema' => 'http://schema.org#', 'license' => 'schema:license' },
    usage_info: { 'schema' => 'http://schema.org#', 'usageInfo' => 'schema:usageInfo' },
    is_based_on: { 'schema' => 'http://schema.org#', 'isBasedOnUrl' => 'schema:isBasedOnUrl' },
    copy_permission: { 'fedibird' => 'http://fedibird.com/ns#', 'copyPermission' => 'fedibird:copyPermission' },
    '_misskey_content': { 'misskey' => 'https://misskey-hub.net/ns#', '_misskey_content' => 'misskey:_misskey_content' },
    '_misskey_quote': { 'misskey' => 'https://misskey-hub.net/ns#', '_misskey_quote' => 'misskey:_misskey_quote' },
    '_misskey_reaction': { 'misskey' => 'https://misskey-hub.net/ns#', '_misskey_reaction' => 'misskey:_misskey_reaction' },
    '_misskey_votes': { 'misskey' => 'https://misskey-hub.net/ns#', '_misskey_votes' => 'misskey:_misskey_votes' },
    '_misskey_summary': { 'misskey' => 'https://misskey-hub.net/ns#', '_misskey_summary' => 'misskey:_misskey_summary' },
    '_misskey_followedMessage': { 'misskey' => 'https://misskey-hub.net/ns#', '_misskey_followedMessage' => 'misskey:_misskey_followedMessage' },
    is_cat: { 'misskey' => 'https://misskey-hub.net/ns#', 'isCat' => 'misskey:isCat' },
    vcard: { 'vcard' => 'http://www.w3.org/2006/vcard/ns#' },
    subscribable_by: { 'kmyblue' => 'http://kmy.blue/ns#', 'subscribableBy' => { '@id' => "kmyblue:subscribableBy", '@type' => '@id' } },
  }.freeze

  def full_context
    serialized_context(NAMED_CONTEXT_MAP, CONTEXT_EXTENSION_MAP)
  end

  def serialized_context(named_contexts_map, context_extensions_map)
    context_array = []

    named_contexts     = named_contexts_map.keys
    context_extensions = context_extensions_map.keys

    named_contexts.each do |key|
      context_array << NAMED_CONTEXT_MAP[key]
    end

    extensions = context_extensions.each_with_object({}) do |key, h|
      h.merge!(CONTEXT_EXTENSION_MAP[key])
    end

    context_array << extensions unless extensions.empty?

    if context_array.size == 1
      context_array.first
    else
      context_array
    end
  end
end
