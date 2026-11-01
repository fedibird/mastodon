# frozen_string_literal: true

module Admin
  class ManagedGroupsController < BaseController
    include GroupAdministrationConcern

    before_action :set_managed_group, only: [:show]

    def index
      authorize_group_admin!(:managed_group, :index?)
      @managed_groups = ManagedGroup.includes(
        :registration_invite_policy,
        :creation_request,
        :account,
        role_assignments: :member_account
      ).joins(:account).merge(Account.local.groups).order(id: :desc).page(params[:page]).per(PAGE_SIZE)
    end

    def show
      authorize_group_admin!(@managed_group, :show?)
      @audits = group_admin_audits(@policy, @creation_request)
    end

    private

    def set_managed_group
      @managed_group = ManagedGroup.includes(
        :registration_invite_policy,
        :account,
        creation_request: [:requester_account, :reviewer_account],
        role_assignments: [:member_account, :granted_by_account]
      ).joins(:account).merge(Account.local.groups).find(params[:id])
      @account = @managed_group.account
      @policy = @managed_group.registration_invite_policy
      @creation_request = @managed_group.creation_request
      assignments = @managed_group.role_assignments
      @owner = assignments.find { |assignment| assignment.owner? && assignment.revoked_at.nil? }
      @moderators = assignments.select { |assignment| assignment.moderator? && assignment.revoked_at.nil? }
    end
  end
end
