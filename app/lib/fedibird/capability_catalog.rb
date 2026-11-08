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
      external_rss_subscriptions
      external_feed_delivery
      posting_context_discovery
      timeline_media_filters
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
        rest: rest,
        activitypub: activitypub,
        integrations: Extensions.integrations,
      }
    end

    def nodeinfo
      {
        schema_version: 1,
        activitypub: activitypub,
      }
    end

    def rest
      {
        supported: REST_SUPPORTED.dup,
        translation: {
          instance_enabled: TranslationService.configured?,
          viewer_scoped: true,
        },
        availability: availability,
        contextual: contextual,
        timeline_filters: timeline_filters,
      }
    end

    # Server-side settings, not permission decisions or health checks.
    # Fields are deliberately named "server_enabled" for allowlisted features:
    # an enabled deployment can still admit zero users.
    def availability
      {
        search: { scope: 'instance', enabled: Chewy.enabled? == true },
        poll_images: { scope: 'instance', enabled: Setting.allow_poll_image == true },
        rss_subscriptions: {
          scope: 'allowlisted_user',
          server_enabled: ExternalBridge::Feature.enabled? == true,
        },
        external_feed_delivery: {
          scope: 'allowlisted_user',
          server_enabled: ExternalBridge::Feeds::Feature.enabled? == true,
          viewer_check_path: '/api/v1/timelines/external_feed_capability',
        },
        emoji_reaction_fallback_policy: {
          scope: 'viewer_and_status',
          # Matches effective? without logging incomplete rollout flags from
          # a public metadata endpoint.
          enforcement_enabled: emoji_reaction_fallback_enforced?,
        },
      }
    end

    def emoji_reaction_fallback_enforced?
      return false unless EmojiReactionCapability::FallbackPolicyConfig.requested?

      EmojiReactionCapability::FallbackPolicyConfig.prerequisites_met?
    end

    # Discovery paths require their own authorization and can return
    # narrower answers. Publishing the route does not grant access to it.
    def contextual
      {
        timeline_seek: {
          scope: 'source_and_kind',
          version: TimelineSeek::Capability::VERSION,
          sources: timeline_seek_sources,
        },
        reading_bookmarks: {
          scope: 'viewer_and_source',
          capability_path: '/api/v1/fedibird/reading_bookmarks/capabilities',
        },
        group_posting: {
          scope: 'viewer_and_actor',
          discovery_path: '/api/v1/fedibird/accounts/:account_id/posting_context',
        },
        emoji_reactions: { scope: 'viewer_and_status' },
        posting_styles: {
          scope: 'administrator',
          collection_path: '/api/v1/fedibird/user_posting_contexts',
          assignments_path: '/api/v1/fedibird/user_posting_context_assignments',
          max_per_user: UserPostingContext::MAX_PER_USER,
        },
      }.merge(Extensions.contextual)
    end

    # These are server-handled REST query parameters, not card/Masonry views.
    # Source identifiers use TimelineSeek names (hashtag instead of "tag").
    def timeline_filters
      {
        only_media: %w(home public hashtag group list personal account),
        without_media: %w(public hashtag group personal),
        compact: %w(home public hashtag group list personal account),
      }
    end

    # Static source/kind bounds; a request may still be downgraded by the
    # resolver due to permissions, remote Groups, or missing retained data.
    def timeline_seek_sources
      (TimelineSeek::Capability::MATRIX.keys + TimelineSeek::Capability::CLOSED_SOURCES).index_with do |source|
        TimelineSeek::Capability::KINDS.index_with do |kind|
          entry = TimelineSeek::Capability.lookup(source, kind)
          { level: entry.level, reason: entry.reason }
        end
      end
    end

    def activitypub
      { supported: ACTIVITYPUB_SUPPORTED.dup }
    end
  end
end
