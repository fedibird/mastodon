# frozen_string_literal: true

class Settings::PostingIdentityRequestAllowancesController < Settings::BaseController
  before_action :require_functional_user!

  def create
    PostingIdentity::RequestAllowance.permit!(
      grantor: current_user,
      acct: params[:acct],
      scopes: params[:scopes]
    )
    redirect_to settings_posting_identity_links_path, notice: I18n.t('posting_identity_links.allowance_saved')
  rescue PostingIdentity::Error => e
    redirect_to settings_posting_identity_links_path, alert: I18n.t("posting_identity_links.errors.#{e.code}")
  end

  def revoke
    allowance = PostingIdentityRequestAllowance.find_by(id: params[:id], grantor_user_id: current_user.id)
    PostingIdentity::RequestAllowance.revoke!(grantor: current_user, allowance: allowance)
    redirect_to settings_posting_identity_links_path, notice: I18n.t('posting_identity_links.allowance_revoked')
  rescue PostingIdentity::Error => e
    redirect_to settings_posting_identity_links_path, alert: I18n.t("posting_identity_links.errors.#{e.code}")
  end

  private

  def require_functional_user!
    forbidden unless current_user&.functional?
  end
end
