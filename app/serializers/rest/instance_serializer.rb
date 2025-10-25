# frozen_string_literal: true

class REST::InstanceSerializer < ActiveModel::Serializer
  class ContactSerializer < ActiveModel::Serializer
    attributes :email

    has_one :account, serializer: REST::AccountSerializer
  end

  include InstanceHelper
  include RoutingHelper

  attributes :domain, :title, :version, :source_url, :description,
             :usage, :thumbnail, :icon, :languages, :configuration,
             :registrations, :api_versions,
             :feature_quote, :fedibird_capabilities

  has_one :contact, serializer: ContactSerializer
  has_many :rules, serializer: REST::RuleSerializer

  def thumbnail
    if object.thumbnail
      {
        url: full_asset_url(object.thumbnail.file.url(:'1x')),
        blurhash: object.thumbnail.blurhash,
        versions: {
          '@1x': full_asset_url(object.thumbnail.file.url(:'1x')),
          '@2x': full_asset_url(object.thumbnail.file.url(:'2x')),
        },
      }
    else
      {
        url: full_pack_url('media/images/preview.jpg'),
      }
    end
  end

  def icon
    {
      src: full_pack_url('media/images/logo.svg'),
      size: "192x192",
    }
  end

  def usage
    {
      users: {
        active_month: object.active_user_count(4),
      },
    }
  end

  def configuration
    {
      urls: {
        streaming: Rails.configuration.x.streaming_api_base_url,
        status: object.status_page_url,
      },

      vapid: {
        public_key: Rails.configuration.x.vapid_public_key,
      },

      accounts: {
        max_featured_tags: FeaturedTag::LIMIT,
        max_pinned_statuses: [StatusPinValidator::LIMIT, Setting.pins_max].min,
        max_favourite_tags: FavouriteTag::LIMIT,
        max_profile_fields: Account::DEFAULT_FIELDS_SIZE,
        max_display_name: LocalDisplayNameValidator::MAX_CHARS,
        characters_reserved_per_emoji: LocalDisplayNameValidator::CUSTOM_EMOJI_PLACEHOLDER_CHARS,
      },

      statuses: {
        max_characters: StatusLengthValidator::MAX_CHARS,
        max_media_attachments: Setting.attachments_max,
        characters_reserved_per_url: StatusLengthValidator::URL_PLACEHOLDER_CHARS,
        min_expiration: TimeLimit::VALID_DURATION.min,
        max_expiration: TimeLimit::VALID_DURATION.max,
        supported_expires_actions: StatusExpire::actions.keys,
      },

      media_attachments: {
        supported_mime_types: MediaAttachment::IMAGE_MIME_TYPES + MediaAttachment::VIDEO_MIME_TYPES + MediaAttachment::AUDIO_MIME_TYPES,
        image_size_limit: MediaAttachment::IMAGE_LIMIT,
        image_matrix_limit: Attachmentable::MAX_MATRIX_LIMIT,
        video_size_limit: MediaAttachment::VIDEO_LIMIT,
        video_frame_rate_limit: MediaAttachment::MAX_VIDEO_FRAME_RATE,
        video_matrix_limit: MediaAttachment::MAX_VIDEO_MATRIX_LIMIT,
        attachments_limit: [MediaAttachment::ATTACHMENTS_LIMIT, Setting.attachments_max].min,
      },

      polls: {
        max_options: PollOptionsValidator::MAX_OPTIONS,
        max_characters_per_option: PollOptionsValidator::MAX_OPTION_CHARS,
        min_expiration: PollExpirationValidator::MIN_EXPIRATION,
        max_expiration: PollExpirationValidator::MAX_EXPIRATION,
        allow_image: Setting.allow_poll_image,
      },

      translation: {
        enabled: false,
      },

      emoji_reactions: {
        max_reactions: EmojiReactionValidator::LIMIT,
        max_reactions_per_account: [EmojiReactionValidator::MAX_PER_ACCOUNT, Setting.reaction_max_per_account].max,
      },

      status_references: {
        max_references: StatusReferenceValidator::LIMIT,
      },

      search: {
        enabled: Chewy.enabled?,
        supported_prefix: SearchQueryTransformer::SUPPORTED_PREFIXES,
        supported_properties: SearchQueryTransformer::SUPPORTED_PROPERTIES,
        supported_operator: SearchQueryTransformer::SUPPORTED_OPERATOR,
        supported_order: SearchQueryTransformer::SUPPORTED_ORDER,
        supported_searchablity_filter: SearchQueryTransformer::SUPPORTED_SEARCHABLITY_FILTER,
      },
    }
  end

  def registrations
    {
      enabled: registrations_enabled?,
      approval_required: Setting.registrations_mode == 'approved',
      message: registrations_enabled? ? nil : registrations_message,
      url: ENV.fetch('SSO_ACCOUNT_SIGN_UP', nil),
    }
  end

  def api_versions
    Mastodon::Version.api_versions
  end

  private

  def registrations_enabled?
    Setting.registrations_mode != 'none' && !Rails.configuration.x.single_user_mode
  end

  def registrations_message
    Setting.closed_registrations_message
  end
end
