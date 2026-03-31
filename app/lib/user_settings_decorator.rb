# frozen_string_literal: true

class UserSettingsDecorator
  attr_reader :user, :settings

  def initialize(user)
    @user = user
  end

  def update(settings)
    @settings = settings
    process_update
    profile_change?
  end

  private

  PROFILE_KEYS = %w(
    setting_noindex
    setting_hide_network
    setting_hide_statuses_count
    setting_hide_following_count
    setting_hide_followers_count
    setting_enable_reaction
  ).freeze

  NESTED_KEYS = %w(
    notification_emails
    interactions
  ).freeze

  BOOLEAN_KEYS = %w(
    default_sensitive
    follow_modal
    unfollow_modal
    subscribe_modal
    unsubscribe_modal
    follow_tag_modal
    unfollow_tag_modal
    boost_modal
    delete_modal
    post_reference_modal
    add_reference_modal
    unselect_reference_modal
    delete_scheduled_status_modal
    missing_alt_text_modal
    auto_play_avatar
    auto_play_emoji
    auto_play_header
    auto_play_media
    expand_spoilers
    reduce_motion
    disable_swiping
    system_font_ui
    noindex
    hide_network
    aggregate_reblogs
    show_application
    advanced_layout
    use_blurhash
    use_pending_items
    trends
    crop_images
    confirm_domain_block
    show_follow_button_on_timeline
    show_subscribe_button_on_timeline
    show_followed_by
    follow_button_to_list_adder
    show_navigation_panel
    show_quote_button
    show_bookmark_button
    show_share_button
    show_target
    place_tab_bar_at_bottom
    show_tab_bar_label
    enable_federated_timeline
    enable_limited_timeline
    enable_personal_timeline
    enable_local_timeline
    enable_reaction
    compact_reaction
    disable_reaction_streaming
    show_reply_tree_button
    hide_statuses_count
    hide_following_count
    hide_followers_count
    disable_joke_appearance
    theme_public
    enable_status_reference
    match_visibility_of_references
    hexagon_avatar
    heart_avatar
    burst_avatar
    enable_empty_column
    hide_bot_on_public_timeline
    confirm_follow_from_bot
    show_reload_button
    disable_post
    disable_reactions
    disable_follow
    disable_unfollow
    disable_block
    disable_domain_block
    disable_clear_all_notifications
    disable_account_delete
    disable_relative_time
    disable_report
    hide_direct_from_timeline
    hide_personal_from_timeline
    hide_personal_from_account
    hide_privacy_meta
    hide_link_preview
    hide_photo_preview
    hide_video_preview
    enable_wide_emoji
    enable_wide_emoji_reaction
    unlocked_for_official_app
    use_low_resolution_thumbnails
    use_fullsize_avatar_on_detail
    use_fullsize_header_on_detail
    hide_statuses_count_from_yourself
    hide_following_count_from_yourself
    hide_followers_count_from_yourself
    hide_subscribing_count_from_yourself
    hide_following_from_yourself
    hide_followers_from_yourself
    hide_joined_date_from_yourself
    hide_reaction_counter
    hide_list_of_emoji_reactions_to_posts
    hide_list_of_favourites_to_posts
    hide_list_of_reblogs_to_posts
    hide_list_of_referred_by_to_posts
    hide_reblogged_by
    enable_status_polling
    enable_status_polling_intersection
    disable_auto_focus_to_emoji_search
  ).freeze

  STRING_KEYS = %w(
    default_privacy
    default_language
    theme
    display_media
    new_features_policy
    theme_instance_ticker
    content_font_size
    info_font_size
    content_emoji_reaction_size
    composer_font_size
    composer_min_height
    emoji_scale
    emoji_size_in_single
    emoji_size_in_multi
    emoji_size_in_mix
    emoji_size_in_other
    picker_emoji_size
    default_search_searchability
    default_column_width
    default_expires_in
    default_expires_action
    prohibited_visibilities
    prohibited_words
    max_frequently_used_emojis
  ).freeze

  INTEGER_KEYS = %w(
  ).freeze

  def profile_change?
    settings.keys.intersection(PROFILE_KEYS).any?
  end

  def process_update
    NESTED_KEYS.each do |key|
      user.settings[key] = user.settings[key].merge coerced_settings(key) if change?(key)
    end

    STRING_KEYS.each do |key|
      user.settings[key] = settings["setting_#{key}"] if change?("setting_#{key}")
    end

    BOOLEAN_KEYS.each do |key|
      user.settings[key] = boolean_cast_setting "setting_#{key}" if change?("setting_#{key}")
    end
  end

  def boolean_cast_setting(key)
    ActiveModel::Type::Boolean.new.cast(settings[key])
  end

  def coerced_settings(key)
    coerce_values settings.fetch(key, {})
  end

  def coerce_values(params_hash)
    params_hash.transform_values { |x| ActiveModel::Type::Boolean.new.cast(x) }
  end

  def change?(key)
    !settings[key].nil?
  end
end
