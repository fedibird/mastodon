# frozen_string_literal: true

class InstancePresenter < ActiveModelSerializers::Model
  include Redisable

  attributes :domain, :title, :version, :source_url,
             :description, :languages, :rules, :contact,
             :feature_quote, :fedibird_capabilities

  class ContactPresenter < ActiveModelSerializers::Model
    attributes :email, :account

    def email
      Setting.site_contact_email
    end

    def account
      username, domain = Setting.site_contact_username.strip.gsub(/\A@/, '').split('@', 2)
      domain = nil if TagManager.instance.local_domain?(domain)
      Account.find_remote(username, domain) if username.present?
    end
  end

  def contact
    ContactPresenter.new
  end

  def description
    Setting.site_short_description
  end

  def extended_description
    Setting.site_extended_description
  end

  def contact_account
    Account.find_local(Setting.site_contact_username.strip.gsub(/\A@/, ''))
  end

  def status_page_url
    ''
  end

  def domain
    Rails.configuration.x.local_domain
  end

  def title
    Setting.site_title
  end

  def languages
    [I18n.default_locale]
  end

  def rules
    Rule.ordered
  end

  def user_count
    Rails.cache.fetch('user_count') { User.confirmed.joins(:account).merge(Account.without_suspended).count }
  end

  def active_user_count(weeks = 4)
    Rails.cache.fetch("active_user_count/#{weeks}") do
      ActivityTracker.new('activity:logins', :unique).sum(weeks.weeks.ago)
    end
  end

  def status_count
    Rails.cache.fetch('local_status_count') { Account.local.joins(:account_stat).sum('account_stats.statuses_count') }.to_i
  end

  def domain_count
    Rails.cache.fetch('distinct_domain_count') { Instance.count }
  end

  def sample_accounts
    Rails.cache.fetch('sample_accounts', expires_in: 12.hours) { Account.local.discoverable.popular.limit(3) }
  end

  def version
    Mastodon::Version.to_s
  end

  def source_url
    Mastodon::Version.source_url
  end

  def thumbnail
    @thumbnail ||= Rails.cache.fetch('site_uploads/thumbnail') { SiteUpload.find_by(var: 'thumbnail') }
  end

  def mascot
    @mascot ||= Rails.cache.fetch('site_uploads/mascot') { SiteUpload.find_by(var: 'mascot') }
  end

  def favicon
    return @favicon if defined?(@favicon)

    @favicon ||= Rails.cache.fetch('site_uploads/favicon') { SiteUpload.find_by(var: 'favicon') }
  end

  def app_icon
    return @app_icon if defined?(@app_icon)

    @app_icon ||= Rails.cache.fetch('site_uploads/app_icon') { SiteUpload.find_by(var: 'app_icon') }
  end

  def feature_quote
    true
  end

  def fedibird_capabilities
    capabilities = [
      :favourite_hashtag,
      :favourite_domain,
      :favourite_list,
      :status_expire,
      :follow_no_delivery,
      :follow_hashtag,
      :subscribe_account,
      :subscribe_domain,
      :subscribe_keyword,
      :timeline_home_visibility,
      :timeline_no_local,
      :timeline_domain,
      :timeline_group,
      :timeline_group_directory,
      :visibility_mutual,
      :visibility_limited,
      :visibility_personal,
      :emoji_reaction,
      :misskey_birthday,
      :misskey_location,
      :status_reference,
      :searchability,
      :status_compact_mode,
      :account_conversations,
      :enable_wide_emoji,
      :enable_wide_emoji_reaction,
      :timeline_bookmark_media_option,
      :timeline_favourite_media_option,
      :timeline_emoji_reaction_media_option,
      :timeline_personal_media_option,
      :bulk_get_api_for_accounts,
      :bulk_get_api_for_statuses,
      :filter_v2,
      :sorted_custom_emojis,
      :ordered_media_attachment,
      :followed_message,
    ]

    capabilities << :profile_search unless Chewy.enabled?

    capabilities
  end
end
