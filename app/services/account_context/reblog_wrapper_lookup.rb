# frozen_string_literal: true

# One visible boost wrapper for one account and one original status.
#
# The query is bounded to two rows (account_id + reblog_of_id, newest first).
# It does not scan the account timeline and it does not fetch remote posts.
# Zero rows is "absent". A row StatusPolicy will not show is "unavailable".
# Two rows is "unknown" / ambiguous. The original status id is never returned
# as the wrapper id.
class AccountContext::ReblogWrapperLookup
  Result = Struct.new(:state, :reason, :status_id, :account_id, keyword_init: true)

  def self.call(viewer:, original:, account_id:)
    new(viewer, original, account_id).call
  end

  def initialize(viewer, original, account_id)
    @viewer = viewer
    @original = original
    @account_id = account_id.to_s
  end

  def call
    return unknown('invalid_account') unless decimal_id?(@account_id)
    return unknown('invalid_status') if @original.nil? || !decimal_id?(@original.id.to_s)

    account = Account.find_by(id: @account_id)
    return unknown('account_unknown') unless account

    rows = Status.include_expired
                 .where(account_id: account.id, reblog_of_id: @original.id)
                 .reorder(id: :desc)
                 .limit(2)
                 .to_a

    return absent(account) if rows.empty?
    return unknown('ambiguous', account) if rows.size > 1

    wrapper = rows.first
    return unavailable(account) unless StatusPolicy.new(@viewer, wrapper).show?
    return unknown('original_id', account) if wrapper.id.to_s == @original.id.to_s

    resolved(account, wrapper)
  end

  private

  def decimal_id?(value)
    value.to_s.match?(/\A(?:0|[1-9]\d*)\z/)
  end

  def unknown(reason, account = nil)
    Result.new(state: 'unknown', reason: reason, status_id: nil, account_id: account&.id)
  end

  def absent(account)
    Result.new(state: 'absent', reason: 'not_found', status_id: nil, account_id: account.id)
  end

  def unavailable(account)
    Result.new(state: 'unavailable', reason: 'not_permitted', status_id: nil, account_id: account.id)
  end

  def resolved(account, wrapper)
    Result.new(state: 'resolved', reason: nil, status_id: wrapper.id, account_id: account.id)
  end
end
