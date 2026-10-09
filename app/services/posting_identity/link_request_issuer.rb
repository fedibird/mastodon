# frozen_string_literal: true

class PostingIdentity::LinkRequestIssuer
  RATE_LIMIT = 10
  RATE_WINDOW = 10.minutes

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

    enforce_rate_limit!
    target = local_target!
    normalized = PostingIdentity::Scopes.normalize!(@scopes)
    token = PostingIdentityLinkRequest.generate_token

    request = PostingIdentityLinkRequest.create!(
      requester_user: @requester,
      target_user: target,
      token_digest: PostingIdentityLinkRequest.digest(token),
      scopes: normalized,
      expires_at: PostingIdentityLinkRequest::REQUEST_TTL.from_now
    )

    Result.new(request: request, token: token)
  end

  private

  def tester?(user)
    user&.functional? && user&.can?(:administrator)
  end

  def local_target!
    username, domain = @acct.to_s.strip.delete_prefix('@').split('@', 2)
    raise PostingIdentity::Error, :invalid_target if username.blank? || domain.present?

    account = Account.find_local(username)
    target = account&.user
    raise PostingIdentity::Error, :invalid_target unless account&.local? && account&.user
    raise PostingIdentity::Error, :self_target if target.id == @requester.id

    target
  end

  def enforce_rate_limit!
    keys = ["posting-identity-link:user:#{@requester.id}"]
    keys << "posting-identity-link:ip:#{@ip}" if @ip.present?

    keys.each do |key|
      count = Rails.cache.read(key).to_i
      raise PostingIdentity::Error, :rate_limited if count >= RATE_LIMIT

      Rails.cache.write(key, count + 1, expires_in: RATE_WINDOW)
    end
  end
end
