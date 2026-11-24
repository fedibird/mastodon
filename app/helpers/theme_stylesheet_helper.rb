# frozen_string_literal: true

module ThemeStylesheetHelper
  def theme_stylesheet_tags(theme, preview: false)
    options = { crossorigin: 'anonymous' }
    if preview
      options.merge!(rel: 'preload', as: 'style', 'data-theme-preview': theme)
    else
      options[:'data-active-theme'] = true
    end

    return stylesheet_pack_tag(theme, media: 'all', **options) unless theme == 'system'

    tags = [
      stylesheet_pack_tag('default', media: 'not all and (prefers-color-scheme: light)', **options),
      stylesheet_pack_tag('mastodon-light', media: '(prefers-color-scheme: light)', **options),
    ]
    safe_join(tags)
  end
end
