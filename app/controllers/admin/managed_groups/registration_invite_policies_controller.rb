# frozen_string_literal: true

module Admin
  module ManagedGroups
    class RegistrationInvitePoliciesController < BaseController
      include GroupAdministrationConcern

      before_action :set_managed_group

      def update
        authorize_group_admin!(@managed_group, :update?)
        if @policy.nil?
          redirect_to admin_managed_group_path(@managed_group), alert: t('admin.managed_groups.policy_missing')
          return
        end

        result = GroupRegistrationInvites::UpdatePolicy.call(
          policy: @policy,
          actor_account: current_account,
          attributes: policy_params
        )
        raise Mastodon::NotPermittedError if result.code == :not_authorized

        finish_update(result)
      end

      private

      def set_managed_group
        @managed_group = ManagedGroup.includes(
          :registration_invite_policy,
          :account,
          creation_request: [:requester_account, :reviewer_account],
          role_assignments: [:member_account, :granted_by_account]
        ).joins(:account).merge(Account.local.groups).find(params[:managed_group_id])
        @account = @managed_group.account
        @policy = @managed_group.registration_invite_policy
        @creation_request = @managed_group.creation_request
        assignments = @managed_group.role_assignments
        @owner = assignments.find { |assignment| assignment.owner? && assignment.revoked_at.nil? }
        @moderators = assignments.select { |assignment| assignment.moderator? && assignment.revoked_at.nil? }
      end

      def policy_params
        params.require(:group_registration_invite_policy).permit(
          :issuance_enabled,
          :shared_registration_quota,
          :shared_quota_unlimited,
          :per_link_max_uses,
          :per_link_unlimited_uses,
          :per_link_lifetime_seconds,
          :per_link_indefinite,
          :lock_version
        )
      end

      def finish_update(result)
        if result.success?
          audit_saved_policy(result.policy)
          redirect_to admin_managed_group_path(@managed_group), notice: t('admin.managed_groups.policy_saved')
          return
        end

        audit_group_action(:fail, result.policy, code: result.code)
        @policy = result.policy
        @audits = group_admin_audits(@policy, @creation_request)
        flash.now[:alert] = t("admin.managed_groups.policy_errors.#{result.code}", default: t('admin.managed_groups.policy_errors.invalid'))
        render 'admin/managed_groups/show'
      end

      def audit_saved_policy(policy)
        return if policy.previous_changes.except('updated_at', 'lock_version').empty?

        audit_group_action(:update, policy)
      end
    end
  end
end
