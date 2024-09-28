# frozen_string_literal: true

module AccountSettings
  extend ActiveSupport::Concern

  included do
    after_initialize :setting_initialize
  end

  def cat?
    true & settings['is_cat']
  end

  alias cat cat?

  def cat=(val)
    settings['is_cat'] = true & ActiveModel::Type::Boolean.new.cast(val)
  end

  def cat_ears_color
    settings['cat_ears_color']
  end

  def birthday
    settings['birthday']
  end

  def birthday=(val)
    set_birthday(val)
  end

  def birth_year
    settings['birth_year'] || birthday && ActiveRecord::Type::Date.new.cast(birthday).year
  end

  def birth_year=(val)
    settings['birth_year'] = Integer(val).then { |val| (0..9999).cover?(val) ? val : nil } rescue nil
    normalize_birthday
  end

  def birth_month
    settings['birth_month'] || birthday && ActiveRecord::Type::Date.new.cast(birthday).month
  end

  def birth_month=(val)
    settings['birth_month'] = Integer(val).then { |val| (1..12).cover?(val) ? val : nil } rescue nil
    normalize_birthday
  end

  def birth_day
    settings['birth_day'] || birthday && ActiveRecord::Type::Date.new.cast(birthday).day
  end

  def birth_day=(val)
    settings['birth_day'] = Integer(val).then { |val| (1..31).cover?(val) ? val : nil } rescue nil
    normalize_birthday
  end

  def normalize_birthday
    date = Date.new(settings['birth_year'], settings['birth_month'], settings['birth_day']) rescue nil
    set_birthday(date)
  end

  def set_birthday(val)
    date = ActiveRecord::Type::Date.new.cast(val)

    if date.class.name === 'Date'
      settings['birthday'] = date
    else
      settings.delete('birthday')
    end
  end

  def location
    settings['location']
  end

  def location=(val)
    settings['location'] = val
  end

  def deny_subscribed?
    true & settings['deny_subscribed']
  end

  def deny_subscribed=(val)
    settings['deny_subscribed'] = true & ActiveModel::Type::Boolean.new.cast(val)
  end

  def followed_message
    settings['followed_message']
  end

  def followed_message=(val)
    settings['followed_message'] = val
  end

  def noindex?
    true & (local? ? user&.noindex? : (settings['noindex'].nil? ? true : settings['noindex']))
  end

  def hide_network?
    true & (local? ? user&.hide_network? : settings['hide_network'])
  end

  def hide_statuses_count?
    true & (local? ? user&.hide_statuses_count? : settings['hide_statuses_count'])
  end

  def hide_following_count?
    true & (local? ? user&.hide_following_count? : settings['hide_following_count'])
  end

  def hide_followers_count?
    true & (local? ? user&.hide_followers_count? : settings['hide_followers_count'])
  end

  def other_settings
    local? && user ? settings.merge(
      {
        'noindex'              => user.setting_noindex,
        'hide_network'         => user.setting_hide_network,
        'hide_statuses_count'  => user.setting_hide_statuses_count,
        'hide_following_count' => user.setting_hide_following_count,
        'hide_followers_count' => user.setting_hide_followers_count,
        'enable_reaction'      => user.setting_enable_reaction,
      }
    ) : settings
  end

  # Called by blurhash_transcoder
  def blurhash=(val)
    settings['cat_ears_color'] = "##{Blurhash::Base83::decode83(val.slice(2,4)).to_s(16).rjust(6, '0')}"
  end

  private

  def setting_initialize
    self[:settings] = {} if has_attribute?(:settings) && self[:settings] === "{}"
  end
end
