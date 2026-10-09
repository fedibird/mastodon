# frozen_string_literal: true

class Settings::PostingIdentityGrantsController < Settings::BaseController
  before_action :require_functional_user!

  def revoke
    finish_revocation(:revoked)
  end

  def unlink
    finish_revocation(:unlinked)
  end

  private

  def finish_revocation(notice_key)
    delegation = PostingIdentityDelegation.find_by(id: params[:id])
    PostingIdentity::Revocation.call!(actor: current_user, delegation: delegation)
    redirect_to settings_posting_identity_links_path, notice: I18n.t("posting_identity_links.#{notice_key}")
  rescue PostingIdentity::Error => e
    redirect_to settings_posting_identity_links_path, alert: I18n.t("posting_identity_links.errors.#{e.code}")
  end

  def require_functional_user!
    forbidden unless current_user&.functional?
  end
end
