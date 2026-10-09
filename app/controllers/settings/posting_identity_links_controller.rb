# frozen_string_literal: true

class Settings::PostingIdentityLinksController < Settings::BaseController
  before_action :require_functional_user!
  before_action :require_administrator!, only: :create

  def index
    load_index
  end

  def create
    result = PostingIdentity::LinkRequestIssuer.call!(
      requester: current_user,
      acct: params[:acct],
      scopes: params[:scopes],
      ip: request.remote_ip
    )
    redirect_to settings_posting_identity_links_path, flash: { posting_identity_token: result.token }
  rescue PostingIdentity::Error => e
    load_index
    flash.now[:alert] = I18n.t("posting_identity_links.errors.#{e.code}")
    render :index, status: (e.code == :rate_limited ? :too_many_requests : :unprocessable_entity)
  end

  def cancel
    request_record = PostingIdentityLinkRequest.find_by(id: params[:id], requester_user_id: current_user.id)
    raise PostingIdentity::Error, :not_found if request_record.nil? || !request_record.open?

    request_record.update!(canceled_at: Time.current)
    redirect_to settings_posting_identity_links_path, notice: I18n.t('posting_identity_links.canceled')
  rescue PostingIdentity::Error => e
    redirect_to settings_posting_identity_links_path, alert: I18n.t("posting_identity_links.errors.#{e.code}")
  end

  private

  def require_functional_user!
    forbidden unless current_user&.functional?
  end

  def require_administrator!
    forbidden unless current_user&.can?(:administrator)
  end

  def load_index
    @received = PostingIdentityDelegation.for_grantee(current_user).includes(:grantor_user, :posting_account).order(approved_at: :desc)
    @granted = PostingIdentityDelegation.for_grantor(current_user).includes(:grantee_user, :posting_account).order(approved_at: :desc)
    @pending = PostingIdentityLinkRequest.where(requester_user_id: current_user.id).includes(:target_user).order(created_at: :desc)
    @allowances = PostingIdentityRequestAllowance.where(grantor_user_id: current_user.id).includes(requester_user: :account).order(allowed_at: :desc)
  end
end
