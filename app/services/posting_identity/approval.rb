# frozen_string_literal: true

class PostingIdentity::Approval
  # The one-time code is the approval secret. ChallengableConcern is not
  # used here: it skips users without a password and does not cover
  # WebAuthn. signed_in_recently? is not a re-authentication either.
  # Approval still requires B's own session, a POST, and CSRF.
  def self.call!(approver:, token:)
    new(approver, token).call!
  end

  def initialize(approver, token)
    @approver = approver
    @token = token.to_s
  end

  def call!
    delegation = nil

    PostingIdentityLinkRequest.transaction do
      request = locked_request
      assert_request!(request)
      assert_parties!(request)
      assert_allowance!(request)
      release_expired_slot!(request)
      delegation = PostingIdentityDelegation.create!(
        grantor_user: request.target_user,
        grantee_user: request.requester_user,
        posting_account: request.target_user.account,
        scopes: request.scopes,
        approved_at: Time.current,
        expires_at: PostingIdentityDelegation::GRANT_TTL.from_now
      )
      request.update!(consumed_at: Time.current)
    end

    delegation
  rescue ActiveRecord::RecordNotUnique
    raise PostingIdentity::Error, :already_delegated
  end

  private

  def locked_request
    digest = PostingIdentityLinkRequest.digest(@token)
    PostingIdentityLinkRequest.lock.find_by(token_digest: digest)
  end

  def assert_request!(request)
    raise PostingIdentity::Error, :invalid_token if request.nil?
    raise PostingIdentity::Error, :consumed if request.consumed_at.present?
    raise PostingIdentity::Error, :canceled if request.canceled_at.present?
    raise PostingIdentity::Error, :expired if request.expired?
    raise PostingIdentity::Error, :invalid_scopes unless PostingIdentity::Scopes.valid?(request.scopes)
  end

  def assert_parties!(request)
    raise PostingIdentity::Error, :not_target unless @approver&.id == request.target_user_id
    raise PostingIdentity::Error, :not_target if @approver&.id == request.requester_user_id
    raise PostingIdentity::Error, :grantor_unavailable unless PostingIdentity::Local.usable?(@approver)
    raise PostingIdentity::Error, :grantor_unavailable unless @approver.account_id == request.target_user.account_id

    grantee = request.requester_user
    raise PostingIdentity::Error, :grantee_unavailable unless grantee&.functional? && grantee&.can?(:administrator)
  end

  def assert_allowance!(request)
    raise PostingIdentity::Error, :allowance_inactive if request.request_allowance_id.nil? || request.allowance_generation.nil?

    allowance = PostingIdentityRequestAllowance.lock.find_by(id: request.request_allowance_id)
    raise PostingIdentity::Error, :allowance_inactive unless allowance&.matches_request?(request)
  end

  def release_expired_slot!(request)
    occupied = PostingIdentityDelegation.lock.occupying_slot.where(
      grantee_user_id: request.requester_user_id,
      grantor_user_id: request.target_user_id
    )

    occupied.each do |grant|
      raise PostingIdentity::Error, :already_delegated if grant.expires_at.future?

      grant.update!(superseded_at: Time.current)
    end
  end
end
