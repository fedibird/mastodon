# frozen_string_literal: true

class InitialStateSerializer < ActiveModel::Serializer
  attributes :meta, :compose, :search, :accounts, :lists,
             :media_attachments, :status_references, :emoji_reactions,
             :settings, :max_toot_chars

  has_one :push_subscription, serializer: REST::WebPushSubscriptionSerializer

  def meta # rubocop:disable Metrics/AbcSize
    store = {
      streaming_api_base_url: Rails.configuration.x.streaming_api_base_url,
      access_token: object.token,
      locale: I18n.locale,
      domain: Rails.configuration.x.local_domain,
      title: instance_presenter.title,
      admin: object.admin&.id&.to_s,
      search_enabled: Chewy.enabled?,
      repository: Mastodon::Version.repository,
      source_url: Mastodon::Version.source_url,
      version: Mastodon::Version.to_s,
      invites_enabled: Setting.min_invite_role == 'user',
      limited_federation_mode: Rails.configuration.x.whitelist_mode,
      mascot: instance_presenter.mascot&.file&.url,
      profile_directory: Setting.profile_directory,
      server_directory: Setting.server_directory,
      trends: Setting.trends,
      allow_poll_image: Setting.allow_poll_image,
      pins_max: [StatusPinValidator::LIMIT, Setting.pins_max].min,
    }

    if object.current_account
      store[:me]                                    = object.current_account.id.to_s
      store[:follow_modal]                          = object.current_account.user.setting_follow_modal
      store[:unfollow_modal]                        = object.current_account.user.setting_unfollow_modal
      store[:subscribe_modal]                       = object.current_account.user.setting_subscribe_modal
      store[:unsubscribe_modal]                     = object.current_account.user.setting_unsubscribe_modal
      store[:follow_tag_modal]                      = object.current_account.user.setting_follow_tag_modal
      store[:unfollow_tag_modal]                    = object.current_account.user.setting_unfollow_tag_modal
      store[:boost_modal]                           = object.current_account.user.setting_boost_modal
      store[:delete_modal]                          = object.current_account.user.setting_delete_modal
      store[:missing_alt_text_modal]                = object.current_account.user.setting_missing_alt_text_modal
      store[:auto_play_avatar]                      = object.current_account.user.setting_auto_play_avatar
      store[:auto_play_emoji]                       = object.current_account.user.setting_auto_play_emoji
      store[:auto_play_header]                      = object.current_account.user.setting_auto_play_header
      store[:auto_play_media]                       = object.current_account.user.setting_auto_play_media
      store[:display_media]                         = object.current_account.user.setting_display_media
      store[:expand_spoilers]                       = object.current_account.user.setting_expand_spoilers
      store[:reduce_motion]                         = object.current_account.user.setting_reduce_motion
      store[:disable_swiping]                       = object.current_account.user.setting_disable_swiping
      store[:advanced_layout]                       = object.current_account.user.setting_advanced_layout
      store[:use_blurhash]                          = object.current_account.user.setting_use_blurhash
      store[:use_pending_items]                     = object.current_account.user.setting_use_pending_items
      store[:is_staff]                              = object.current_account.user.staff?
      store[:trends]                                = Setting.trends && object.current_account.user.setting_trends
      store[:crop_images]                           = object.current_account.user.setting_crop_images
      store[:confirm_domain_block]                  = object.current_account.user.setting_confirm_domain_block
      store[:show_follow_button_on_timeline]        = object.current_account.user.setting_show_follow_button_on_timeline
      store[:show_subscribe_button_on_timeline]     = object.current_account.user.setting_show_subscribe_button_on_timeline
      store[:show_followed_by]                      = object.current_account.user.setting_show_followed_by
      store[:follow_button_to_list_adder]           = object.current_account.user.setting_follow_button_to_list_adder
      store[:show_navigation_panel]                 = object.current_account.user.setting_show_navigation_panel
      store[:show_quote_button]                     = object.current_account.user.setting_show_quote_button
      store[:show_bookmark_button]                  = object.current_account.user.setting_show_bookmark_button
      store[:show_share_button]                     = object.current_account.user.setting_show_share_button
      store[:show_target]                           = object.current_account.user.setting_show_target
      store[:place_tab_bar_at_bottom]               = object.current_account.user.setting_place_tab_bar_at_bottom
      store[:show_tab_bar_label]                    = object.current_account.user.setting_show_tab_bar_label
      store[:enable_federated_timeline]             = object.current_account.user.setting_enable_federated_timeline
      store[:enable_limited_timeline]               = object.current_account.user.setting_enable_limited_timeline
      store[:enable_personal_timeline]              = object.current_account.user.setting_enable_personal_timeline
      store[:enable_local_timeline]                 = false #object.current_account.user.setting_enable_local_timeline
      store[:enable_reaction]                       = object.current_account.user.setting_enable_reaction
      store[:compact_reaction]                      = object.current_account.user.setting_compact_reaction
      store[:disable_reaction_streaming]            = object.current_account.user.setting_disable_reaction_streaming
      store[:show_reply_tree_button]                = object.current_account.user.setting_show_reply_tree_button
      store[:disable_joke_appearance]               = object.current_account.user.setting_disable_joke_appearance
      store[:new_features_policy]                   = object.current_account.user.setting_new_features_policy
      store[:theme_instance_ticker]                 = object.current_account.user.setting_theme_instance_ticker
      store[:theme_public]                          = object.current_account.user.setting_theme_public
      store[:enable_status_reference]               = object.current_account.user.setting_enable_status_reference
      store[:match_visibility_of_references]        = object.current_account.user.setting_match_visibility_of_references
      store[:post_reference_modal]                  = object.current_account.user.setting_post_reference_modal
      store[:add_reference_modal]                   = object.current_account.user.setting_add_reference_modal
      store[:unselect_reference_modal]              = object.current_account.user.setting_unselect_reference_modal
      store[:delete_scheduled_status_modal]         = object.current_account.user.setting_delete_scheduled_status_modal
      store[:enable_empty_column]                   = object.current_account.user.setting_enable_empty_column
      store[:content_font_size]                     = object.current_account.user.setting_content_font_size
      store[:info_font_size]                        = object.current_account.user.setting_info_font_size
      store[:content_emoji_reaction_size]           = object.current_account.user.setting_content_emoji_reaction_size
      store[:emoji_scale]                           = object.current_account.user.setting_emoji_scale
      store[:emoji_size_in_single]                  = object.current_account.user.setting_emoji_size_in_single
      store[:emoji_size_in_multi]                   = object.current_account.user.setting_emoji_size_in_multi
      store[:emoji_size_in_mix]                     = object.current_account.user.setting_emoji_size_in_mix
      store[:emoji_size_in_other]                   = object.current_account.user.setting_emoji_size_in_other
      store[:picker_emoji_size]                     = object.current_account.user.setting_picker_emoji_size
      store[:enable_wide_emoji]                     = object.current_account.user.setting_enable_wide_emoji
      store[:enable_wide_emoji_reaction]            = object.current_account.user.setting_enable_wide_emoji_reaction
      store[:hide_bot_on_public_timeline]           = object.current_account.user.setting_hide_bot_on_public_timeline
      store[:confirm_follow_from_bot]               = object.current_account.user.setting_confirm_follow_from_bot
      store[:show_reload_button]                    = object.current_account.user.setting_show_reload_button
      store[:default_column_width]                  = object.current_account.user.setting_default_column_width
      store[:disable_post]                          = object.current_account.user.setting_disable_post
      store[:disable_reactions]                     = object.current_account.user.setting_disable_reactions
      store[:disable_follow]                        = object.current_account.user.setting_disable_follow
      store[:disable_unfollow]                      = object.current_account.user.setting_disable_unfollow
      store[:disable_block]                         = object.current_account.user.setting_disable_block
      store[:disable_domain_block]                  = object.current_account.user.setting_disable_domain_block
      store[:disable_report]                        = object.current_account.user.setting_disable_report
      store[:disable_clear_all_notifications]       = object.current_account.user.setting_disable_clear_all_notifications
      store[:disable_account_delete]                = object.current_account.user.setting_disable_account_delete
      store[:disable_relative_time]                 = object.current_account.user.setting_disable_relative_time
      store[:hide_direct_from_timeline]             = object.current_account.user.setting_hide_direct_from_timeline
      store[:hide_personal_from_timeline]           = object.current_account.user.setting_hide_personal_from_timeline
      store[:hide_personal_from_account]            = object.current_account.user.setting_hide_personal_from_account
      store[:hide_privacy_meta]                     = object.current_account.user.setting_hide_privacy_meta
      store[:hide_link_preview]                     = object.current_account.user.setting_hide_link_preview
      store[:hide_photo_preview]                    = object.current_account.user.setting_hide_photo_preview
      store[:hide_video_preview]                    = object.current_account.user.setting_hide_video_preview
      store[:use_low_resolution_thumbnails]         = object.current_account.user.setting_use_low_resolution_thumbnails
      store[:use_fullsize_avatar_on_detail]         = object.current_account.user.setting_use_fullsize_avatar_on_detail
      store[:use_fullsize_header_on_detail]         = object.current_account.user.setting_use_fullsize_header_on_detail
      store[:hide_following_from_yourself]          = object.current_account.user.setting_hide_following_from_yourself
      store[:hide_followers_from_yourself]          = object.current_account.user.setting_hide_followers_from_yourself
      store[:hide_statuses_count_from_yourself]     = object.current_account.user.setting_hide_statuses_count_from_yourself
      store[:hide_following_count_from_yourself]    = object.current_account.user.setting_hide_following_count_from_yourself
      store[:hide_followers_count_from_yourself]    = object.current_account.user.setting_hide_followers_count_from_yourself
      store[:hide_subscribing_count_from_yourself]  = object.current_account.user.setting_hide_subscribing_count_from_yourself
      store[:hide_joined_date_from_yourself]        = object.current_account.user.setting_hide_joined_date_from_yourself
      store[:hide_reaction_counter]                 = object.current_account.user.setting_hide_reaction_counter
      store[:hide_list_of_emoji_reactions_to_posts] = object.current_account.user.setting_hide_list_of_emoji_reactions_to_posts
      store[:hide_list_of_favourites_to_posts]      = object.current_account.user.setting_hide_list_of_favourites_to_posts
      store[:hide_list_of_reblogs_to_posts]         = object.current_account.user.setting_hide_list_of_reblogs_to_posts
      store[:hide_list_of_referred_by_to_posts]     = object.current_account.user.setting_hide_list_of_referred_by_to_posts
      store[:hide_reblogged_by]                     = object.current_account.user.setting_hide_reblogged_by
      store[:enable_status_polling]                 = object.current_account.user.setting_enable_status_polling
      store[:enable_status_polling_intersection]    = object.current_account.user.setting_enable_status_polling_intersection
      store[:disable_auto_focus_to_emoji_search]    = object.current_account.user.setting_disable_auto_focus_to_emoji_search
      store[:max_frequently_used_emojis]            = object.current_account.user.setting_max_frequently_used_emojis
      
    else
      store[:auto_play_avatar] = Setting.auto_play_avatar
      store[:auto_play_emoji]  = Setting.auto_play_emoji
      store[:auto_play_header] = Setting.auto_play_header
      store[:auto_play_media]  = Setting.auto_play_media
      store[:display_media]    = Setting.display_media
      store[:reduce_motion]    = Setting.reduce_motion
      store[:use_blurhash]     = Setting.use_blurhash
      store[:crop_images]      = Setting.crop_images
    end

    store
  end

  def compose
    store = {}

    if object.current_account
      store[:me]                      = object.current_account.id.to_s
      store[:default_privacy]         = object.visibility || object.current_account.user.setting_default_privacy
      store[:default_searchability]   = object.current_account.searchability
      store[:default_sensitive]       = object.current_account.user.setting_default_sensitive
      store[:default_expires_in]      = object.current_account.user.setting_default_expires_in
      store[:default_expires_action]  = object.current_account.user.setting_default_expires_action
      store[:prohibited_visibilities] = object.current_account.user.setting_prohibited_visibilities.filter(&:present?)
      store[:prohibited_words]        = (object.current_account.user.setting_prohibited_words || '').split(',').map(&:strip).filter(&:present?)
      store[:poll_max_options]        = [PollOptionsValidator::MAX_OPTIONS, Setting.poll_max_options].max
    end

    store[:text] = object.text if object.text

    store
  end

  def max_toot_chars
    StatusLengthValidator::MAX_CHARS
  end

  def search
    store = {}
    store[:default_searchability] = object.current_account.user.setting_default_search_searchability if object.current_account
    store
  end

  def accounts
    store = {}
    store[object.current_account.id.to_s] = ActiveModelSerializers::SerializableResource.new(object.current_account, serializer: REST::AccountSerializer) if object.current_account
    store[object.admin.id.to_s]           = ActiveModelSerializers::SerializableResource.new(object.admin, serializer: REST::AccountSerializer) if object.admin
    store
  end

  def lists
    store = {}
    store = ActiveModelSerializers::SerializableResource.new(object.current_account.owned_lists, each_serializer: REST::ListSerializer) if object.current_account
    store
  end

  def media_attachments
    {
      accept_content_types: MediaAttachment.supported_file_extensions + MediaAttachment.supported_mime_types,
      max_attachments: [MediaAttachment::ATTACHMENTS_LIMIT, Setting.attachments_max].min,
    }
  end

  def status_references
    { max_references: StatusReferenceValidator::LIMIT }
  end

  def emoji_reactions
    { max_reactions_per_account: [EmojiReactionValidator::MAX_PER_ACCOUNT, Setting.reaction_max_per_account].max }
  end

  private

  def instance_presenter
    @instance_presenter ||= InstancePresenter.new
  end
end
