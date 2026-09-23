# frozen_string_literal: true

module Admin
  class Users::RolesController < BaseController
    before_action :set_user

    def show
      authorize @user, :change_role?
      @assignable_roles = assignable_roles
    end

    def update
      authorize @user, :change_role?
      @assignable_roles = assignable_roles

      if @user.assign_user_role!(requested_role, current_account: current_account)
        log_action :change_role, @user
        redirect_to admin_account_path(@user.account_id), notice: I18n.t('admin.accounts.change_role.changed_msg')
      else
        render :show
      end
    end

    private

    def set_user
      @user = User.find(params[:user_id])
    end

    def requested_role
      role_id = resource_params[:role_id]
      return if role_id.blank?

      UserRole.find(role_id)
    end

    def resource_params
      params.require(:user).permit(:role_id)
    end

    # Equal positions stay assignable. A higher position is elevation.
    def assignable_roles
      actor_role = current_user.user_role
      UserRole.assignable.reject { |candidate| candidate.overrides?(actor_role) }
    end
  end
end
