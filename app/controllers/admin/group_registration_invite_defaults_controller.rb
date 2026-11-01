# frozen_string_literal: true

module Admin
  class GroupRegistrationInviteDefaultsController < BaseController
    include GroupAdministrationConcern

    def edit
      authorize_group_admin!(:group_registration_invite_defaults, :show?)
      @form = Form::GroupRegistrationInviteDefaults.from_settings
      @snapshot = GroupRegistrationInvites::SiteDefaults.snapshot
    end

    def update
      authorize_group_admin!(:group_registration_invite_defaults, :update?)
      result = GroupRegistrationInvites::UpdateSiteDefaults.call(
        actor_account: current_account,
        attributes: defaults_params,
        fingerprint: params.dig(:form_group_registration_invite_defaults, :fingerprint).to_s
      )
      raise Mastodon::NotPermittedError if result.code == :not_authorized

      finish_update(result)
    end

    private

    def defaults_params
      params.require(:form_group_registration_invite_defaults).permit(
        :issuance_enabled,
        :shared_registration_quota,
        :shared_quota_unlimited,
        :per_link_max_uses,
        :per_link_unlimited_uses,
        :per_link_lifetime_seconds,
        :per_link_indefinite,
        :fingerprint
      )
    end

    def finish_update(result)
      if result.success?
        redirect_to edit_admin_group_registration_invite_defaults_path, notice: t('admin.group_registration_invite_defaults.saved')
        return
      end

      @snapshot = GroupRegistrationInvites::SiteDefaults.snapshot
      @form = result.code == :conflict ? Form::GroupRegistrationInviteDefaults.from_settings : Form::GroupRegistrationInviteDefaults.from_submission(defaults_params)
      if result.code == :audit_failed
        flash.now[:alert] = t('admin.group_administration.audit_failed')
      end
      result.errors.each do |code|
        next if code == :audit_failed

        @form.errors.add(:base, t("admin.group_registration_invite_defaults.errors.#{code}", default: t('admin.group_administration.audit_failed')))
      end
      render :edit
    end
  end
end
