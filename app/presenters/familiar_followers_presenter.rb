# frozen_string_literal: true

class FamiliarFollowersPresenter
  class Result < ActiveModelSerializers::Model
    attributes :id, :accounts
  end

  def initialize(accounts, current_account_id)
    @accounts = accounts
    @current_account_id = current_account_id
  end

  def accounts
    map = follows_by_target_account_id

    @accounts.map do |account|
      Result.new(
        id: account.id,
        accounts: familiar_accounts_for(account, map)
      )
    end
  end

  private

  def follows_by_target_account_id
    return {} if @accounts.empty?

    followed_account_ids = Follow.where(account_id: @current_account_id).select(:target_account_id)

    Follow
      .includes(account: [:account_stat, :user])
      .where(target_account_id: @accounts.map(&:id))
      .where(account_id: followed_account_ids)
      .group_by(&:target_account_id)
  end

  def familiar_accounts_for(account, map)
    return [] if hide_requested_followers?(account)

    (map[account.id] || []).map(&:account).reject(&:hide_following?)
  end

  def hide_requested_followers?(account)
    account.hide_followers? || (account.id == @current_account_id && account.user&.setting_hide_followers_from_yourself)
  end
end
