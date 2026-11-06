# frozen_string_literal: true

# Public implementation discovery. These methods never make viewer or
# target-specific authorization decisions.
module Fedibird
  module CapabilityCatalog
    # Preserve the original ordering and conditional profile_search entry.
    LEGACY_CAPABILITIES = %i(
      favourite_hashtag
      favourite_domain
      favourite_list
      status_expire
      follow_no_delivery
      follow_hashtag
      subscribe_account
      subscribe_domain
      subscribe_keyword
      timeline_home_visibility
      timeline_no_local
      timeline_domain
      timeline_group
      timeline_group_directory
      visibility_mutual
      visibility_limited
      visibility_personal
      emoji_reaction
      misskey_birthday
      misskey_location
      status_reference
      searchability
      status_compact_mode
      account_conversations
      enable_wide_emoji
      enable_wide_emoji_reaction
      timeline_bookmark_media_option
      timeline_favourite_media_option
      timeline_emoji_reaction_media_option
      timeline_personal_media_option
      bulk_get_api_for_accounts
      bulk_get_api_for_statuses
      filter_v2
      sorted_custom_emojis
      ordered_media_attachment
      followed_message
    ).freeze

    # "supported" means implemented, not necessarily authorized or enabled.
    REST_SUPPORTED = %w(
      emoji_reactions
      status_references
      status_expiration
      status_searchability
      extended_visibilities
      filters_v2
      group_directory
      timeline_seek
      reading_bookmarks
      preferences_schema
      status_translation
    ).freeze

    # Software-level AP serializer behavior, not FEP conformance or
    # authorization to post to any specific Group actor.
    ACTIVITYPUB_SUPPORTED = %w(
      emoji_react
      note_references
      legacy_quote_uri
      searchable_by
      group_actor
    ).freeze

    module_function

    def legacy
      capabilities = LEGACY_CAPABILITIES.dup
      capabilities << :profile_search unless Chewy.enabled?
      capabilities
    end

    def instance
      {
        schema_version: 1,
        rest: {
          supported: REST_SUPPORTED.dup,
          translation: {
            instance_enabled: TranslationService.configured?,
            viewer_scoped: true,
          },
        },
        activitypub: {
          supported: ACTIVITYPUB_SUPPORTED.dup,
        },
      }
    end

    def nodeinfo
      {
        schema_version: 1,
        activitypub: {
          supported: ACTIVITYPUB_SUPPORTED.dup,
        },
      }
    end
  end
end
