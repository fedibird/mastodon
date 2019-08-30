# frozen_string_literal: true

class UnsubscribeAccountService < BaseService
  # UnsubscribeAccount
  # @param [Account] source_account Where to unsubscribe from
  # @param [Account] target_account Which to unsubscribe
  def call(source_account, target_account)
    subscribe = AccountSubscribe.find_by(account: source_account, target_account: target_account)

    return unless subscribe

    subscribe.destroy!
    UnmergeWorker.perform_async(target_account.id, source_account.id)
    subscribe
  end
end
