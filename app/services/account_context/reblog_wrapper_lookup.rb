# frozen_string_literal: true

# One visible boost wrapper for one account and one original status.
#
# The query keeps only wrappers this viewer is allowed to see, then reads two
# of those rows, newest first. Hidden wrappers never enter that limit, so any
# number of them leaves one visible wrapper resolved and two visible wrappers
# ambiguous. It does not scan the account timeline and it does not fetch
# remote posts. StatusPolicy#show? still checks the rows that come back, and
# a row it rejects is not returned. The original status id is never returned
# as the wrapper id.
class AccountContext::ReblogWrapperLookup
  OPEN_VISIBILITIES = %w(public unlisted mutual).freeze
  MENTION_VISIBILITIES = %w(private direct limited).freeze
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
    return absent(account) if account.suspended?

    candidates = visible_candidates(account)
    ExternalBridge::ProjectionAccess.prepare!(candidates)
    visible = candidates.select { |wrapper| StatusPolicy.new(@viewer, wrapper).show? }

    return unknown('ambiguous', account) if visible.size > 1
    return absent(account) if visible.empty?

    wrapper = visible.first
    return unknown('original_id', account) if wrapper.id.to_s == @original.id.to_s

    resolved(account, wrapper)
  end

  private

  def decimal_id?(value)
    value.to_s.match?(/\A(?:0|[1-9]\d*)\z/)
  end

  def visible_candidates(account)
    scope = Status.include_expired
                  .where(account_id: account.id, reblog_of_id: @original.id)
                  .where('statuses.ap_object_type IS NULL OR statuses.ap_object_type <> ?', Status::AP_OBJECT_TYPE_PAGE)
    scope = scope.where(visibility_clause(account)) unless owner?(account)
    scope.reorder(id: :desc).limit(2).to_a
  end

  def owner?(account)
    @viewer.present? && @viewer.id == account.id
  end

  # Subset of StatusPolicy#show? for this one author. A row the policy would
  # reject must stay out of the limit, or it could hide an older visible wrapper.
  def visibility_clause(account)
    return non_expired_open if @viewer.nil?

    open_allowed = open_allowed?(account)
    clauses = []
    clauses << (engaged_with_original? ? open_visibility : non_expired_open) if open_allowed
    clauses << (engaged_with_original? ? private_visibility : non_expired_private) if @viewer.following?(account)
    clauses << mentioned_visibility(open_allowed)
    clauses.reduce { |combined, clause| combined.or(clause) }
  end

  def open_allowed?(account)
    !account.blocking?(@viewer) && !viewer_blocks_author_domain?(account)
  end

  def viewer_blocks_author_domain?(account)
    account.domain.present? && @viewer.domain_blocking?(account.domain)
  end

  def engaged_with_original?
    return @engaged_with_original if defined?(@engaged_with_original)

    @engaged_with_original =
      Favourite.where(account_id: @viewer.id, status_id: @original.id).exists? ||
      Bookmark.where(account_id: @viewer.id, status_id: @original.id).exists? ||
      EmojiReaction.enabled.where(account_id: @viewer.id, status_id: @original.id).exists?
  end

  def non_expired_open
    open_visibility.and(not_expired)
  end

  def non_expired_private
    private_visibility.and(not_expired)
  end

  def open_visibility
    visibility.in(visibility_values(OPEN_VISIBILITIES))
  end

  def private_visibility
    visibility.eq(Status.visibilities.fetch('private'))
  end

  def not_expired
    status_table[:expired_at].eq(nil)
  end

  def mentioned_visibility(include_open)
    names = include_open ? MENTION_VISIBILITIES + OPEN_VISIBILITIES : MENTION_VISIBILITIES
    visibility.in(visibility_values(names)).and(mentioned_by_viewer)
  end

  def mentioned_by_viewer
    mentions = Mention.arel_table
    exists = mentions.project(mentions[:id])
                     .where(mentions[:status_id].eq(status_table[:id]))
                     .where(mentions[:account_id].eq(@viewer.id))
    Arel::Nodes::Exists.new(exists)
  end

  def visibility
    status_table[:visibility]
  end

  def visibility_values(names)
    names.map { |name| Status.visibilities.fetch(name) }
  end

  def status_table
    Status.arel_table
  end

  def unknown(reason, account = nil)
    Result.new(state: 'unknown', reason: reason, status_id: nil, account_id: account&.id)
  end

  def absent(account)
    Result.new(state: 'absent', reason: 'not_found', status_id: nil, account_id: account.id)
  end

  def resolved(account, wrapper)
    Result.new(state: 'resolved', reason: nil, status_id: wrapper.id, account_id: account.id)
  end
end
