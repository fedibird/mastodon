# frozen_string_literal: true

class Settings::PreferencesController < Settings::BaseController
  before_action :set_account, only: [:update]

  def show; end

  def update
    if user_settings.update(user_settings_params.to_h)
      ActivityPub::UpdateDistributionWorker.perform_async(@account.id)
    end

    if current_user.update(user_params)
      I18n.locale = current_user.locale
      redirect_to after_update_redirect_path, notice: I18n.t('generic.changes_saved_msg')
    else
      render :show
    end
  end

  private

  def after_update_redirect_path
    settings_preferences_path
  end

  def user_settings
    UserSettingsDecorator.new(current_user)
  end

  def user_params
    params.require(:user).permit(
      :locale,
      chosen_languages: []
    )
  end

  def user_settings_params
    params.require(:user).permit(
      :setting_default_privacy,
      :setting_default_sensitive,
      :setting_default_language,
      :setting_unfollow_modal,
      :setting_unsubscribe_modal,
      :setting_boost_modal,
      :setting_delete_modal,
      :setting_auto_play_gif,
      :setting_display_media,
      :setting_expand_spoilers,
      :setting_reduce_motion,
      :setting_disable_swiping,
      :setting_system_font_ui,
      :setting_noindex,
      :setting_theme,
      :setting_hide_network,
      :setting_aggregate_reblogs,
      :setting_show_application,
      :setting_advanced_layout,
      :setting_use_blurhash,
      :setting_use_pending_items,
      :setting_trends,
      :setting_crop_images,
      :setting_show_follow_button_on_timeline,
      :setting_show_subscribe_button_on_timeline,
      :setting_show_followed_by,
      :setting_follow_button_to_list_adder,
      :setting_show_navigation_panel,
      :setting_show_quote_button,
      :setting_show_bookmark_button,
      :setting_show_share_button,
      :setting_place_tab_bar_at_bottom,
      :setting_show_tab_bar_label,
      :setting_show_target,
      :setting_enable_federated_timeline,
      :setting_enable_limited_timeline,
      :setting_enable_personal_timeline,
      :setting_enable_local_timeline,
      :setting_enable_reaction,
      :setting_compact_reaction,
      :setting_disable_reaction_streaming,
      :setting_show_reply_tree_button,
      :setting_hide_statuses_count,
      :setting_hide_following_count,
      :setting_hide_followers_count,
      :setting_disable_joke_appearance,
      :setting_new_features_policy,
      :setting_theme_instance_ticker,
      :setting_theme_public,
      :setting_hexagon_avatar,
      :setting_enable_status_reference,
      :setting_match_visibility_of_references,
      :setting_post_reference_modal,
      :setting_add_reference_modal,
      :setting_unselect_reference_modal,
      :setting_delete_scheduled_status_modal,
      :setting_enable_empty_column,
      :setting_content_font_size,
      :setting_info_font_size,
      :setting_composer_font_size,
      :setting_composer_min_height,
      :setting_content_emoji_reaction_size,
      :setting_emoji_scale,
      :setting_emoji_size_in_single,
      :setting_emoji_size_in_multi,
      :setting_emoji_size_in_mix,
      :setting_emoji_size_in_other,
      :setting_picker_emoji_size,
      :setting_enable_wide_emoji,
      :setting_enable_wide_emoji_reaction,
      :setting_hide_bot_on_public_timeline,
      :setting_confirm_follow_from_bot,
      :setting_default_search_searchability,
      :setting_show_reload_button,
      :setting_default_column_width,
      :setting_confirm_domain_block,
      :setting_default_expires_in,
      :setting_default_expires_action,
      :setting_disable_post,
      :setting_disable_reactions,
      :setting_disable_follow,
      :setting_disable_unfollow,
      :setting_disable_block,
      :setting_disable_domain_block,
      :setting_disable_clear_all_notifications,
      :setting_disable_account_delete,
      :setting_prohibited_words,
      :setting_disable_relative_time,
      :setting_hide_direct_from_timeline,
      :setting_hide_personal_from_timeline,
      :setting_hide_personal_from_account,
      :setting_hide_privacy_meta,
      :setting_hide_link_preview,
      :setting_hide_photo_preview,
      :setting_hide_video_preview,
      :setting_unlocked_for_official_app,
      :setting_use_low_resolution_thumbnails,
      :setting_use_fullsize_avatar_on_detail,
      :setting_use_fullsize_header_on_detail,
      :setting_hide_statuses_count_from_yourself,
      :setting_hide_following_count_from_yourself,
      :setting_hide_followers_count_from_yourself,
      :setting_hide_subscribing_count_from_yourself,
      :setting_hide_following_from_yourself,
      :setting_hide_followers_from_yourself,
      :setting_hide_joined_date_from_yourself,
      :setting_hide_reaction_counter,
      :setting_hide_list_of_emoji_reactions_to_posts,
      :setting_hide_list_of_favourites_to_posts,
      :setting_hide_list_of_reblogs_to_posts,
      :setting_hide_list_of_referred_by_to_posts,
      :setting_hide_reblogged_by,
      :setting_enable_status_polling,
      :setting_enable_status_polling_intersection,
      :setting_disable_auto_focus_to_emoji_search,
      :setting_max_frequently_used_emojis,
      setting_prohibited_visibilities: [],
      notification_emails: %i(follow follow_request followed_message reblog favourite emoji_reaction status_reference mention digest report pending_account trending_tag),
      interactions: %i(must_be_follower must_be_following must_be_following_dm must_be_following_newcommer must_be_following_newcommer_dm must_be_dm_to_send_email must_be_following_reference)
    )
  end

  def set_account
    @account = current_account
  end
end
