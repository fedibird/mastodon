# frozen_string_literal: true

# Personal management is separate from server administration. Every record
# lookup is scoped to an active local role; all writes recheck under a lock.
class Settings::ManagedGroupsController < Settings::BaseController
  before_action :require_local_person!
  before_action :set_managed_group, only: [:show, :appoint_moderator, :revoke_moderator, :resign_moderator, :offer_transfer, :cancel_transfer]

  def index
    @memberships = GroupRoleAssignment.active.where(member_account_id: current_account.id).index_by(&:group_account_id)
    @managed_groups = ManagedGroup.approved_request.where(account_id: @memberships.keys).includes(:account).order(id: :desc)
    @incoming_offers = GroupOwnerTransferOffer.pending
                                              .where(candidate_account_id: current_account.id)
                                              .where('expires_at > ?', Time.current)
                                              .includes(:group_account, :offered_by_account)
                                              .order(id: :desc)
  end

  def show
    @viewer_role = GroupRoleAssignment.active.find_by!(
      group_account_id: @managed_group.account_id,
      member_account_id: current_account.id
    )
    @owner = GroupRoleAssignment.active.owner.includes(:member_account).find_by!(group_account_id: @managed_group.account_id)
    @moderators = GroupRoleAssignment.active.moderator.where(group_account_id: @managed_group.account_id).includes(:member_account).order(:id)
    @pending_offer = GroupOwnerTransferOffer.pending.includes(:candidate_account).find_by(group_account_id: @managed_group.account_id) if @viewer_role.owner?
  end

  def appoint_moderator
    status = GroupRoles::Moderators.appoint(
      managed_group: @managed_group,
      actor_account: current_account,
      target_account: local_person(params[:username])
    )
    finish(status, settings_managed_group_path(@managed_group))
  end

  def revoke_moderator
    status = GroupRoles::Moderators.revoke(
      managed_group: @managed_group,
      actor_account: current_account,
      target_account_id: params[:member_account_id]
    )
    finish(status, settings_managed_group_path(@managed_group))
  end

  def resign_moderator
    status = GroupRoles::Moderators.resign(
      managed_group: @managed_group,
      actor_account: current_account
    )
    finish(status, settings_managed_groups_path)
  end

  def offer_transfer
    status = GroupRoles::OwnerTransfers.offer(
      managed_group: @managed_group,
      actor_account: current_account,
      candidate_account: local_person(params[:username])
    )
    finish(status, settings_managed_group_path(@managed_group))
  end

  def cancel_transfer
    offer = GroupOwnerTransferOffer.find_by(id: params[:offer_id], group_account_id: @managed_group.account_id)
    status = offer ? GroupRoles::OwnerTransfers.cancel(offer: offer, actor_account: current_account) : :not_pending
    finish(status, settings_managed_group_path(@managed_group))
  end

  def accept_transfer
    offer = GroupOwnerTransferOffer.where(candidate_account_id: current_account.id).find(params[:offer_id])
    status = GroupRoles::OwnerTransfers.accept(offer: offer, actor_account: current_account)
    finish(status, settings_managed_groups_path)
  end

  private

  def require_local_person!
    forbidden unless GroupManagement.local_functional_person?(current_account)
  end

  def set_managed_group
    ids = GroupRoleAssignment.active.where(member_account_id: current_account.id).select(:group_account_id)
    @managed_group = ManagedGroup.approved_request.where(account_id: ids).find(params[:id])
  end

  def local_person(value)
    username = value.to_s.strip.delete_prefix('@').downcase
    return unless username.match?(GroupCreationRequest::USERNAME_PATTERN)

    Account.local.find_by(username: username)
  end

  def finish(status, path)
    return forbidden if status == :not_authorized

    key = "group_role_management.results.#{status}"
    if %i(appointed revoked resigned offered cancelled accepted).include?(status)
      redirect_to path, notice: t(key)
    else
      redirect_to path, alert: t(key, default: t('group_role_management.results.conflict'))
    end
  end
end
