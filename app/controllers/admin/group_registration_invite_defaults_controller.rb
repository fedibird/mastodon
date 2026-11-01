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
      before = GroupRegistrationInvites::SiteDefaults.snapshot
      result = GroupRegistrationInvites::UpdateSiteDefaults.call(
        actor_account: current_account,
        attributes: defaults_params,
        fingerprint: params.dig(:form_group_registration_invite_defaults, :fingerprint).to_s
      )
      raise Mastodon::NotPermittedError if result.code == :not_authorized

      finish_update(result, before)
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

    def finish_update(result, before)
      if result.success?
        audit_defaults(before)
        redirect_to edit_admin_group_registration_invite_defaults_path, notice: t('admin.group_registration_invite_defaults.saved')
        return
      end

      audit_group_action(:fail_group_invite_defaults, current_account, code: result.code)
      @snapshot = GroupRegistrationInvites::SiteDefaults.snapshot
      @form = result.code == :conflict ? Form::GroupRegistrationInviteDefaults.from_settings : Form::GroupRegistrationInviteDefaults.from_submission(defaults_params)
      result.errors.each do |code|
        @form.errors.add(:base, t("admin.group_registration_invite_defaults.errors.#{code}"))
      end
      render :edit
    end

    def audit_defaults(before)
      setting = defaults_setting
      return if setting.nil?

      after = GroupRegistrationInvites::SiteDefaults.snapshot
      return if before == after

      audit_group_action(:update_group_invite_defaults, setting, changes: { 'before' => before.stringify_keys, 'after' => after.stringify_keys })
    end

    def defaults_setting
      Setting.find_by(var: 'group_registration_invites_enabled')
    end
  end
end
