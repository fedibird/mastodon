# frozen_string_literal: true

class ManifestSerializer < ActiveModel::Serializer
  include RoutingHelper
  include InstanceHelper
  include ActionView::Helpers::TextHelper

  attributes :name, :short_name, :description,
             :icons, :theme_color, :background_color,
             :display, :start_url, :scope,
             :share_target, :shortcuts

  def name
    object.title
  end

  def short_name
    object.title
  end

  def description
    strip_tags(object.description.presence || I18n.t('about.about_mastodon_html'))
  end

  def icons
    if instance_presenter.app_icon.present?
      SiteUpload::ANDROID_ICON_SIZES.map do |size|
        {
          src: absolute_icon_url(app_icon_path(size)),
          sizes: "#{size}x#{size}",
          type: 'image/png',
          purpose: 'any maskable',
        }
      end
    else
      [
        {
          src: absolute_icon_url('/android-chrome-192x192.png'),
          sizes: '192x192',
          type: 'image/png',
          purpose: 'any maskable',
        },
      ]
    end
  end

  def theme_color
    '#282c37'
  end

  def background_color
    '#191b22'
  end

  def display
    'standalone'
  end

  def start_url
    '/web/timelines/home'
  end

  def scope
    root_url
  end

  def share_target
    {
      url_template: 'share?title={title}&text={text}&url={url}',
      action: 'share',
      method: 'GET',
      enctype: 'application/x-www-form-urlencoded',
      params: {
        title: 'title',
        text: 'text',
        url: 'url',
      },
    }
  end

  def absolute_icon_url(src)
    return if src.blank?

    URI.join(root_url, src).to_s
  end

  def shortcuts
    [
      {
        name: 'New toot',
        url: '/web/statuses/new',
        icons: [
          {
            src: '/shortcuts/new-status.png',
            type: 'image/png',
            sizes: '192x192',
          },
        ],
      },
      {
        name: 'Notifications',
        url: '/web/notifications',
        icons: [
          {
            src: '/shortcuts/notifications.png',
            type: 'image/png',
            sizes: '192x192',
          },
        ],
      },
      {
        name: 'Direct messages',
        url: '/web/timelines/direct',
        icons: [
          {
            src: '/shortcuts/direct.png',
            type: 'image/png',
            sizes: '192x192',
          },
        ],
      },
    ]
  end
end
