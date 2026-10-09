# frozen_string_literal: true

class Settings::PostingIdentityApprovalsController < Settings::BaseController
  before_action :require_functional_user!

  def new; end

  def preview
    @link_request = open_request!
    @grant_expires_at = PostingIdentityDelegation::GRANT_TTL.from_now
  rescue PostingIdentity::Error => e
    flash.now[:alert] = I18n.t("posting_identity_links.errors.#{e.code}")
    render :new, status: :unprocessable_entity
  end

  def create
    PostingIdentity::Approval.call!(approver: current_user, token: params[:token])
    redirect_to settings_posting_identity_links_path, notice: I18n.t('posting_identity_links.approved')
  rescue PostingIdentity::Error => e
    flash.now[:alert] = I18n.t("posting_identity_links.errors.#{e.code}")
    render :new, status: :unprocessable_entity
  end

  private

  def require_functional_user!
    forbidden unless current_user&.functional?
  end

  def open_request!
    request_record = PostingIdentityLinkRequest.find_by(token_digest: PostingIdentityLinkRequest.digest(params[:token]))
    raise PostingIdentity::Error, :invalid_token if request_record.nil?
    raise PostingIdentity::Error, :not_target unless current_user.id == request_record.target_user_id
    raise PostingIdentity::Error, :consumed if request_record.consumed_at.present?
    raise PostingIdentity::Error, :canceled if request_record.canceled_at.present?
    raise PostingIdentity::Error, :expired if request_record.expired?

    request_record
  end
end
