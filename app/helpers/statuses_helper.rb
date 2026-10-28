# frozen_string_literal: true

module StatusesHelper
  EMBEDDED_CONTROLLER = 'statuses'
  EMBEDDED_ACTION = 'embed'

  def link_to_newer(url)
    link_to t('statuses.show_newer'), url, class: 'load-more load-gap'
  end

  def link_to_older(url)
    link_to t('statuses.show_older'), url, class: 'load-more load-gap'
  end

  def nothing_here(extra_classes = '')
    content_tag(:div, class: "nothing-here #{extra_classes}") do
      t('accounts.nothing_here')
    end
  end

  def media_summary(status)
    attachments = { image: 0, video: 0, audio: 0 }

    status.media_attachments.each do |media|
      if media.video?
        attachments[:video] += 1
      elsif media.audio?
        attachments[:audio] += 1
      else
        attachments[:image] += 1
      end
    end

    text = attachments.to_a.reject { |_, value| value.zero? }.map { |key, value| I18n.t("statuses.attached.#{key}", count: value) }.join(' · ')

    return if text.blank?

    I18n.t('statuses.attached.description', attached: text)
  end

  def status_text_summary(status)
    return if status.spoiler_text.blank?

    I18n.t('statuses.content_warning', warning: status.spoiler_text)
  end

  def poll_summary(status)
    return unless status.preloadable_poll

    status.preloadable_poll.options.map { |o| "[ ] #{o}" }.join("\n")
  end

  def status_description(status)
    components = [[media_summary(status), status_text_summary(status)].reject(&:blank?).join(' · ')]

    if status.spoiler_text.blank?
      components << Formatter.instance.plaintext(status)
      components << poll_summary(status)
    end

    components.reject(&:blank?).join("\n\n")
  end

  def reference_description(status)
    components = [status_text_summary(status)]

    if status.spoiler_text.blank?
      components << [Formatter.instance.plaintext(status).chomp, media_summary(status)].reject(&:blank?).join(' · ')
      components << poll_summary(status)
    end

    components.reject(&:blank?).join("\n\n")
  end

  def stream_link_target
    embedded_view? ? '_blank' : nil
  end

  def style_classes(status, is_predecessor, is_successor, include_threads)
    classes = ['entry']
    classes << 'entry-predecessor' if is_predecessor
    classes << 'entry-reblog' if status.reblog?
    classes << 'entry-successor' if is_successor
    classes << 'entry-center' if include_threads
    classes.join(' ')
  end

  def microformats_classes(status, is_direct_parent, is_direct_child)
    classes = []
    classes << 'p-in-reply-to' if is_direct_parent
    classes << 'p-repost-of' if status.reblog? && is_direct_parent
    classes << 'p-comment' if is_direct_child
    classes.join(' ')
  end

  def microformats_h_class(status, is_predecessor, is_successor, include_threads)
    if is_predecessor || status.reblog? || is_successor
      'h-cite'
    elsif include_threads
      ''
    else
      'h-entry'
    end
  end

  def fa_visibility_icon(status)
    case status.visibility
    when 'public'
      fa_icon 'globe fw'
    when 'unlisted'
      fa_icon 'unlock fw'
    when 'private'
      fa_icon 'lock fw'
    when 'mutual'
      fa_icon 'exchange fw'
    when 'limited'
      fa_icon 'user-circle fw'
    when 'direct'
      fa_icon 'envelope fw'
    when 'personal'
      fa_icon 'book fw'
    end
  end

  def sensitized?(status, account)
    if !account.nil? && account.id == status.account_id
      status.sensitive
    else
      status.account.sensitized? || status.sensitive
    end
  end

  def noindex?(statuses)
    statuses.map(&:account).uniq.any?(&:noindex?)
  end

  private

  def simplified_text(text)
    text.dup.tap do |new_text|
      URI.extract(new_text).each do |url|
        new_text.gsub!(url, '')
      end

      new_text.gsub!(Account::MENTION_RE, '')
      new_text.gsub!(Tag::HASHTAG_RE, '')
      new_text.gsub!(/\s+/, '')
    end
  end

  def embedded_view?
    params[:controller] == EMBEDDED_CONTROLLER && params[:action] == EMBEDDED_ACTION
  end

  # Public pages use the same split as the signed-in WebUI: images and GIFV
  # stay in one gallery, then every video and audio attachment stacks in its
  # original relative order. The serialized list stays in attachment order;
  # StatusMediaStack partitions it in the browser.
  def render_status_media(status, **options)
    attachments = status.ordered_media_attachments
    return if attachments.empty?

    react_component :status_media_stack, status_media_component_params(status, attachments, options) do
      render partial: 'statuses/attachment_list', locals: { attachments: attachments }
    end
  end

  # Older single-type entry points share the stack so a later attachment is
  # not dropped when the first one is a video or an audio file.
  def render_video_component(status, **options)
    render_status_media(status, **options)
  end

  def render_audio_component(status, **options)
    render_status_media(status, **options)
  end

  def render_media_gallery_component(status, **options)
    render_status_media(status, **options)
  end

  # One card. Networks that only keep the first player tag would otherwise
  # advertise whichever attachment happened to be written last.
  def representative_opengraph_attachment(status)
    return unless status.respond_to?(:ordered_media_attachments)

    status.ordered_media_attachments.find { |media| media.image? || media.gifv? || media.video? || media.audio? }
  end

  def render_card_component(status, **options)
    component_params = {
      sensitive: sensitized?(status, current_account),
      maxDescription: 160,
      card: ActiveModelSerializers::SerializableResource.new(status.preview_card, serializer: REST::PreviewCardSerializer).as_json,
    }.merge(**options)

    react_component :card, component_params
  end

  def render_poll_component(status, **options)
    component_params = {
      disabled: true,
      poll: ActiveModelSerializers::SerializableResource.new(status.preloadable_poll, serializer: REST::PollSerializer, scope: current_user, scope_name: :current_user).as_json,
    }.merge(**options)

    react_component :poll, component_params do
      render partial: 'statuses/poll', locals: { status: status, poll: status.preloadable_poll, autoplay: prefers_autoplay? }
    end
  end

  def prefers_autoplay?
    ActiveModel::Type::Boolean.new.cast(params[:autoplay]) || current_user&.setting_auto_play_media
  end

  def status_media_component_params(status, attachments, options)
    height = options.fetch(:height, 343)
    component_params = {
      sensitive: options.fetch(:sensitive) { status_media_sensitive?(status, options[:quote]) },
      autoplay: prefers_autoplay?,
      height: height,
      videoHeight: options.fetch(:video_height, height),
      audioHeight: options.fetch(:audio_height, height),
      defaultWidth: options[:width],
      standalone: options[:standalone] || false,
      quote: options[:quote] || false,
      posterFallback: full_asset_url(status.account.avatar_static_url),
      media: attachments.map { |attachment| ActiveModelSerializers::SerializableResource.new(attachment, serializer: REST::MediaAttachmentSerializer).as_json },
    }
    component_params[:detailed] = true if options[:detailed]
    component_params.compact
  end

  def status_media_sensitive?(status, quote)
    if quote
      (!current_account&.user&.show_all_media? && status.sensitive?) || current_account&.user&.hide_all_media?
    else
      sensitized?(status, current_account)
    end
  end
end
