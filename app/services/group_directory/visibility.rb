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
    return unless classification_matches?(account)
    return unless text_matches?(account)

    account
  end

  # ES can still say lemmy/ja/local after NodeInfo, group_languages, or
  # domain have changed. The candidate id is kept only when the current
  # row matches the requested software, language, and scope.
  def classification_matches?(account)
    software_matches?(account) && language_matches?(account) && scope_matches?(account)
  end

  def scope_matches?(account)
    return true unless @parsed.scope == 'local'

    account.local?
  end

  def software_matches?(account)
    name = @parsed.software
    return true if name.nil?

    case name
    when 'fedibird', 'unknown', 'other'
      GroupDirectory::Document.software_bucket(account) == name
    else
      GroupDirectory::Document.software_name(account) == name
    end
  end

  def language_matches?(account)
    tags = GroupDirectory::Document.language_tags(account)
    case @parsed.language
    when nil
      true
    when :unset
      tags.empty?
    else
      tags.include?(@parsed.language)
    end
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
