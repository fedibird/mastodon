# frozen_string_literal: true

class Web::NotificationSerializer < ActiveModel::Serializer
  include RoutingHelper
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::SanitizeHelper

  attributes :access_token, :preferred_locale, :notification_id,
             :notification_type, :icon, :title, :body

  def access_token
    current_push_subscription.associated_access_token
  end

  def preferred_locale
    current_push_subscription.associated_user&.locale || I18n.default_locale
  end

  def notification_id
    object.id
  end

  def notification_type
    object.type
  end

  def icon
    full_asset_url(object.from_account.avatar_static_url)
  end

  def title
    type = status_boost? ? :status_boost : object.type
    I18n.t("notification_mailer.#{type}.subject", name: object.from_account.display_name.presence || object.from_account.username)
  end

  def body
    status = status_boost? ? object.target_status.reblog : object.target_status
    text = status&.spoiler_text.presence || status&.text
    str = strip_tags(text || (status_boost? ? '' : object.from_account.note))
    truncate(HTMLEntities.new.decode(str.to_s), length: 140, escape: !status_boost?) # Boost bodies are plain text, not HTML
  end

  private

  def status_boost?
    object.type == :status && object.target_status&.reblog_of_id.present?
  end
end
