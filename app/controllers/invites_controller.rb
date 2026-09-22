# frozen_string_literal: true

class InvitesController < ApplicationController
  include Authorization

  layout 'admin'

  before_action :authenticate_user!
  before_action :set_body_classes

  def index
    authorize :invite, :create?

    @invites = invites
    @invite_reviews = InviteCreation::ReviewLookup.for_invites(@invites)
    @invite = Invite.new
  end

  def create
    authorize :invite, :create?

    result = InviteCreation::CreateService.new.call(user: current_user, attributes: resource_params)
    if result.issued?
      redirect_to invites_path
    elsif result.pending_review?
      redirect_to invites_path, notice: I18n.t('invites.pending_review')
    else
      @invite = result.invite
      @invites = invites
      @invite_reviews = InviteCreation::ReviewLookup.for_invites(@invites)
      render :index
    end
  end

  def destroy
    @invite = invites.find(params[:id])
    authorize @invite, :destroy?
    InviteCreation::ReviewLookup.management_expire!(@invite)
    redirect_to invites_path
  end

  private

  def invites
    current_user.invites.order(id: :desc)
  end

  def resource_params
    params.require(:invite).permit(:max_uses, :expires_in, :autofollow, :comment)
  end

  def set_body_classes
    @body_classes = 'admin'
  end
end
