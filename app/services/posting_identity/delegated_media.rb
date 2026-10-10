# frozen_string_literal: true

class PostingIdentity::DelegatedMedia
  # Attaching is separate from account ownership. The signed-in grantee
  # may attach only still images that this delegation uploaded.
  def self.collect!(account:, media_ids:, audit:)
    new(account, media_ids, audit).collect!
  end

  def initialize(account, media_ids, audit)
    @account = account
    @media_ids = media_ids
    @audit = audit || {}
  end

  def collect!
    return [] if @media_ids.blank?

    ids = unique_ids
    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.too_many') if ids.size > Setting.attachments_max

    delegation = fresh_delegation
    owned = @account.media_attachments.where(status_id: nil, scheduled_status_id: nil, id: ids).index_by(&:id)
    raise Mastodon::NotPermittedError unless owned.size == ids.size

    audits = PostingIdentityMedia.where(
      media_attachment_id: ids,
      grantee_user_id: delegation.grantee_user_id,
      delegation_id: delegation.id,
      posting_account_id: @account.id
    ).index_by(&:media_attachment_id)
    raise Mastodon::NotPermittedError unless audits.size == ids.size

    media = ids.map { |id| owned[id] }
    raise Mastodon::ValidationError, I18n.t('posting_identity_links.delegated_media_type') unless media.all? { |item| PostingIdentity::StillImage.acceptable?(item) }
    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.not_ready') if media.any?(&:not_processed?)

    media
  end

  private

  def unique_ids
    raise Mastodon::NotPermittedError unless @media_ids.is_a?(Enumerable)

    ids = @media_ids.map do |value|
      token = value.to_s
      raise Mastodon::NotPermittedError unless token.match?(/\A[1-9]\d*\z/)

      token.to_i
    end
    ids.uniq
  end

  def fresh_delegation
    delegation = PostingIdentityDelegation.includes(:grantee_user, :grantor_user, :posting_account).find_by(id: @audit[:delegation_id])
    grantee = delegation&.grantee_user
    raise Mastodon::NotPermittedError unless grantee && grantee.id == @audit[:grantee_user_id].to_i
    raise Mastodon::NotPermittedError unless PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: delegation, operation: 'post')
    raise Mastodon::NotPermittedError unless PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: delegation, operation: 'media')
    raise Mastodon::NotPermittedError unless delegation.posting_account_id == @account.id
    raise Mastodon::NotPermittedError unless @audit[:posting_account_id].to_i == @account.id
    raise Mastodon::NotPermittedError unless delegation.posting_account&.local?

    delegation
  end
end
