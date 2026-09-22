# frozen_string_literal: true

module Admin
  class InvitesController < BaseController
    def index
      authorize :invite, :index?

      @invites = filtered_invites.includes(user: :account).page(params[:page])
      @invite_reviews = InviteCreation::ReviewLookup.for_invites(@invites)
      @invite = Invite.new
    end

    def create
      authorize :invite, :create?

      result = InviteCreation::CreateService.new.call(user: current_user, attributes: resource_params)
      if result.issued?
        redirect_to admin_invites_path
      elsif result.pending_review?
        redirect_to admin_invites_path, notice: I18n.t('invites.pending_review')
      else
        @invite = result.invite
        @invites = Invite.page(params[:page])
        @invite_reviews = InviteCreation::ReviewLookup.for_invites(@invites)
        render :index
      end
    end

    def destroy
      @invite = Invite.find(params[:id])
      authorize @invite, :destroy?
      InviteCreation::ReviewLookup.management_expire!(@invite)
      redirect_to admin_invites_path
    end

    def deactivate_all
      authorize :invite, :deactivate_all?
      Invite.available.in_batches.update_all(expires_at: Time.now.utc)
      redirect_to admin_invites_path
    end

    private

    def resource_params
      params.require(:invite).permit(:max_uses, :expires_in)
    end

    def filtered_invites
      InviteFilter.new(filter_params).results
    end

    def filter_params
      params.slice(*InviteFilter::KEYS).permit(*InviteFilter::KEYS)
    end
  end
end
