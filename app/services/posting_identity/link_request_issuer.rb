# frozen_string_literal: true

class PostingIdentity::LinkRequestIssuer
  RATE_LIMIT = 10
  RATE_WINDOW = 10.minutes
  PAIR_LIMIT = 3
  PAIR_WINDOW = 30.minutes

  Result = Struct.new(:request, :token, keyword_init: true)

  def self.call!(requester:, acct:, scopes:, ip:)
    new(requester: requester, acct: acct, scopes: scopes, ip: ip).call!
  end

  def initialize(requester:, acct:, scopes:, ip:)
    @requester = requester
    @acct = acct
    @scopes = scopes
    @ip = ip.to_s
  end

  def call!
    raise PostingIdentity::Error, :not_administrator unless tester?(@requester)

    hit_limit!("posting-identity-link:user:#{@requester.id}", RATE_LIMIT, RATE_WINDOW)
    hit_limit!("posting-identity-link:ip:#{@ip}", RATE_LIMIT, RATE_WINDOW) if @ip.present?
    normalized = PostingIdentity::Scopes.normalize!(@scopes)
    target = local_target
    raise PostingIdentity::Error, :self_target if target&.id == @requester.id
    raise PostingIdentity::Error, :request_unavailable unless target&.functional?

    request = nil
    token = nil

    PostingIdentityRequestAllowance.transaction do
      allowance = PostingIdentityRequestAllowance.lock.find_by(grantor_user_id: target.id, requester_user_id: @requester.id)
      raise PostingIdentity::Error, :request_unavailable unless allowance&.active? && allowance&.covers?(normalized)
      raise PostingIdentity::Error, :duplicate_request if open_request?(target, allowance)

      hit_limit!("posting-identity-link:pair:#{@requester.id}:#{target.id}", PAIR_LIMIT, PAIR_WINDOW)
      token = PostingIdentityLinkRequest.generate_token
      request = PostingIdentityLinkRequest.create!(
        requester_user: @requester,
        target_user: target,
        token_digest: PostingIdentityLinkRequest.digest(token),
        scopes: normalized,
        expires_at: PostingIdentityLinkRequest::REQUEST_TTL.from_now,
        request_allowance: allowance,
        allowance_generation: allowance.generation
      )
    end

    Rails.logger.info(
      "posting_identity_link_request issued id=#{request.id} requester_user_id=#{request.requester_user_id} target_user_id=#{request.target_user_id} request_allowance_id=#{request.request_allowance_id} allowance_generation=#{request.allowance_generation}"
    )
    Result.new(request: request, token: token)
  end

  private

  def tester?(user)
    user&.functional? && user&.can?(:administrator)
  end

  def local_target
    username, domain = @acct.to_s.strip.delete_prefix('@').split('@', 2)
    return nil if username.blank? || domain.present?

    account = Account.find_local(username)
    return nil unless account&.local? && account&.user

    account.user
  end

  # Only an unused, unexpired request from the current allowance generation
  # blocks another code. An older generation stays on record and does not.
  def open_request?(target, allowance)
    PostingIdentityLinkRequest.where(
      requester_user_id: @requester.id,
      target_user_id: target.id,
      request_allowance_id: allowance.id,
      allowance_generation: allowance.generation,
      consumed_at: nil,
      canceled_at: nil
    ).where('expires_at > ?', Time.current).exists?
  end

  def hit_limit!(key, limit, window)
    count = Rails.cache.increment(key, 1, expires_in: window)
    if count.nil?
      Rails.cache.write(key, 1, expires_in: window)
      count = 1
    end
    raise PostingIdentity::Error, :rate_limited if count > limit
  end
end
