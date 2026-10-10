# frozen_string_literal: true

# A delegated post is a new public, unlisted, or followers-only status.
# Still images are allowed when the grant also includes media. Replies,
# groups, polls, and schedules stay out. The check runs before reply,
# circle, schedule, and expiry lookups so the signed-in user's defaults
# cannot reshape the delegated post.
class PostingIdentity::DelegatedTextPost
  ALLOWED_VISIBILITIES = %w(public unlisted private).freeze
  QT_PATTERN = /QT:\s*\[\s*https:\/\/.+?\]/i

  def self.authorize!(resolution:, params:)
    new(resolution, params).authorize!
  end

  def self.resolved_visibility(resolution, params)
    params[:visibility].presence || resolution.account.user&.setting_default_privacy.presence || 'public'
  end

  def initialize(resolution, params)
    @resolution = resolution
    @params = params
  end

  def authorize!
    raise Mastodon::NotPermittedError unless @resolution&.delegated?
    raise Mastodon::NotPermittedError unless PostingIdentity::DelegationResolver.grant_permits?(
      grantee: @resolution.delegation.grantee_user,
      delegation: @resolution.delegation,
      operation: 'post'
    )
    raise Mastodon::NotPermittedError if media_requested? && !PostingIdentity::DelegationResolver.grant_permits?(
      grantee: @resolution.delegation.grantee_user,
      delegation: @resolution.delegation,
      operation: 'media'
    )

    raise unsupported if unsupported_shape?
    raise unsupported unless self.class::ALLOWED_VISIBILITIES.include?(self.class.resolved_visibility(@resolution, @params).to_s)
  end

  private

  def unsupported
    Mastodon::ValidationError.new(I18n.t('posting_identity_links.delegated_unsupported'))
  end

  def unsupported_shape?
    present?(@params[:in_reply_to_id]) ||
      present?(@params[:quote_id]) ||
      present?(@params[:circle_id]) ||
      present?(@params[:audience_account_id]) ||
      present?(@params[:poll]) ||
      present?(@params[:scheduled_at]) ||
      present?(@params[:scheduled_in]) ||
      present?(@params[:expires_at]) ||
      present?(@params[:expires_in]) ||
      present?(@params[:status_reference_ids]) ||
      present?(@params[:status_reference_urls]) ||
      present?(@params[:allowed_mentions]) ||
      marked_quote?(@params[:status]) ||
      marked_quote?(@params[:spoiler_text]) ||
      explicit_mention?(@params[:status]) ||
      explicit_mention?(@params[:spoiler_text])
  end

  def marked_quote?(text)
    text.to_s.match?(QT_PATTERN)
  end

  def explicit_mention?(text)
    text.to_s.match?(Account::MENTION_RE)
  end

  def media_requested?
    present?(@params[:media_ids])
  end

  def present?(value)
    case value
    when nil
      false
    when String
      value.present?
    when Array
      value.any? { |item| present?(item) }
    when ActionController::Parameters, Hash
      value.values.any? { |item| present?(item) }
    else
      value.respond_to?(:present?) ? value.present? : !value.nil?
    end
  end
end
