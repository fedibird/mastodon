# frozen_string_literal: true

# Current visibility of Elasticsearch candidate ids.
#
# The index can still hold a document after a group is unlisted, blocked,
# or edited. This loads only those ids from PostgreSQL, in the index order,
# and drops anything the viewer must not see. It does not ILIKE the accounts
# table and it does not send the viewer's follows or mutes to Elasticsearch.
#
# This is the last check before the controller serializes the page.
class GroupDirectory::Visibility
  class << self
    def keep(viewer:, ids:, parsed:)
      new(viewer, parsed).keep(ids)
    end
  end

  def initialize(viewer, parsed)
    @viewer = viewer
    @parsed = parsed
  end

  def keep(ids)
    ordered = Array(ids).map(&:to_i).select(&:positive?).uniq
    return [] if ordered.empty?

    records = load_records(ordered)
    hidden = hidden_ids(records)
    followed = followed_ids(records)
    blocked_domains = blocked_domains(records)

    ordered.filter_map do |id|
      accept(records[id], hidden, followed, blocked_domains)
    end
  end

  private

  def load_records(ids)
    GroupDirectory::Eligibility.scope.where(id: ids).index_by(&:id)
  end

  def accept(account, hidden, followed, blocked_domains)
    return if account.nil?
    return unless GroupDirectory::Eligibility.eligible?(account)
    return if hidden.include?(account.id)
    return if account.domain.present? && blocked_domains.include?(account.domain)
    return if @parsed.following? && !followed.include?(account.id)
    return unless text_matches?(account)

    account
  end

  def text_matches?(account)
    if @parsed.exact?
      exact_match?(account)
    elsif @parsed.substring?
      GroupDirectory::SearchText.contiguous?(account, @parsed.query)
    else
      true
    end
  end

  def exact_match?(account)
    acct = @parsed.acct
    return false unless account.username.to_s.downcase == acct[:username]
    return true unless acct[:domain_constrained]

    GroupDirectory::Document.domain_key(account) == acct[:domain]
  end

  def hidden_ids(records)
    return Set.new if @viewer.nil? || records.empty?

    ids = records.keys
    hidden = Block.where(account_id: @viewer.id, target_account_id: ids).pluck(:target_account_id)
    hidden.concat(Block.where(account_id: ids, target_account_id: @viewer.id).pluck(:account_id))
    hidden.concat(Mute.where(account_id: @viewer.id, target_account_id: ids).pluck(:target_account_id))
    hidden.to_set
  end

  def followed_ids(records)
    return Set.new unless @parsed.following? && @viewer && records.any?

    Follow.where(account_id: @viewer.id, target_account_id: records.keys).pluck(:target_account_id).to_set
  end

  def blocked_domains(records)
    return Set.new if @viewer.nil?

    domains = records.values.map(&:domain).select(&:present?).uniq
    return Set.new if domains.empty?

    AccountDomainBlock.where(account_id: @viewer.id, domain: domains).pluck(:domain).to_set
  end
end
