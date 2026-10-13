# frozen_string_literal: true

class PostingIdentity::DelegationResolver
  # A stored grant is not permission to post. Callers re-check the parties,
  # the account, the clock, and the requested scope. reply and quote also
  # require post, and they are never implied by an older post grant.
  def self.grant_permits?(grantee:, delegation:, operation:)
    return false unless relationship_active?(grantee: grantee, delegation: delegation)

    name = operation.to_s
    scopes = Array(delegation.scopes).map(&:to_s)
    return false unless PostingIdentity::Scopes::ALLOWED.include?(name) && scopes.include?(name)
    return false if %w(reply quote).include?(name) && !scopes.include?('post')

    true
  end

  def self.relationship_active?(grantee:, delegation:)
    return false if delegation.nil? || grantee.nil?
    return false unless delegation.grantee_user_id == grantee.id
    return false if delegation.revoked_at.present? || delegation.superseded_at.present?
    return false unless delegation.expires_at&.future?
    return false unless grantee.functional? && grantee.can?(:administrator)

    grantor = delegation.grantor_user
    account = delegation.posting_account
    return false if grantor.nil? || account.nil?
    return false unless grantor.account_id == account.id
    return false unless grantor.account_id == delegation.posting_account_id
    return false unless PostingIdentity::Local.usable?(grantor)

    true
  end
end
