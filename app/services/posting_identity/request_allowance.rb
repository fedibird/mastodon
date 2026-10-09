# frozen_string_literal: true

class PostingIdentity::RequestAllowance
  INSERT_ATTEMPTS = 3

  # Letting A ask is not a posting grant. Only B can create or revoke the
  # allowance, and a later approval still has to match this generation.
  def self.permit!(grantor:, acct:, scopes:)
    new(grantor, acct, scopes).permit!
  end

  def self.revoke!(grantor:, allowance:)
    raise PostingIdentity::Error, :not_found if allowance.nil?
    raise PostingIdentity::Error, :not_owner unless grantor&.id == allowance.grantor_user_id
    return allowance if allowance.revoked_at.present?

    allowance.update!(revoked_at: Time.current)
    Rails.logger.info(
      "posting_identity_request_allowance revoked id=#{allowance.id} grantor_user_id=#{allowance.grantor_user_id} requester_user_id=#{allowance.requester_user_id} generation=#{allowance.generation}"
    )
    allowance
  end

  def initialize(grantor, acct, scopes)
    @grantor = grantor
    @acct = acct
    @scopes = scopes
  end

  def permit!
    raise PostingIdentity::Error, :grantor_unavailable unless @grantor&.functional?
    requester = local_requester!
    normalized = PostingIdentity::Scopes.normalize!(@scopes)
    record = nil
    attempt = 0

    begin
      attempt += 1
      PostingIdentityRequestAllowance.transaction do
        existing = PostingIdentityRequestAllowance.lock.find_by(grantor_user_id: @grantor.id, requester_user_id: requester.id)
        record = write!(existing, requester, normalized)
      end
    rescue ActiveRecord::RecordNotUnique
      retry if attempt < INSERT_ATTEMPTS
      raise PostingIdentity::Error, :allowance_conflict
    end

    Rails.logger.info(
      "posting_identity_request_allowance permit id=#{record.id} grantor_user_id=#{record.grantor_user_id} requester_user_id=#{record.requester_user_id} generation=#{record.generation}"
    )
    record
  end

  private

  def local_requester!
    username, domain = @acct.to_s.strip.delete_prefix('@').split('@', 2)
    raise PostingIdentity::Error, :invalid_target if username.blank? || domain.present?

    account = Account.find_local(username)
    requester = account&.user
    raise PostingIdentity::Error, :invalid_target unless account&.local? && account&.user && requester&.functional?
    raise PostingIdentity::Error, :self_target if requester.id == @grantor.id

    requester
  end

  def write!(record, requester, normalized)
    return insert!(requester, normalized) if record.nil?
    return record if record.active? && same_scopes?(record, normalized)

    now = Time.current
    generation = record.generation
    generation += 1 if record.revoked_at.present? || !record.expires_at.future? || !same_scopes?(record, normalized)
    record.update!(
      allowed_scopes: normalized,
      allowed_at: now,
      expires_at: PostingIdentityRequestAllowance::TTL.from_now,
      revoked_at: nil,
      generation: generation
    )
    record
  end

  def insert!(requester, normalized)
    PostingIdentityRequestAllowance.create!(
      grantor_user: @grantor,
      requester_user: requester,
      allowed_scopes: normalized,
      allowed_at: Time.current,
      expires_at: PostingIdentityRequestAllowance::TTL.from_now,
      generation: 1
    )
  end

  def same_scopes?(record, normalized)
    Array(record.allowed_scopes).map(&:to_s).sort == normalized.sort
  end
end
