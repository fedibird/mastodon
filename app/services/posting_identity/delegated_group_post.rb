# frozen_string_literal: true

# Shared entry for a delegated group post. Local Fedibird groups keep
# their follow and mention rules. Remote groups are authorized separately
# and do not fall through to a normal post.
class PostingIdentity::DelegatedGroupPost
  Outcome = Struct.new(:allowed_mentions, :audience_account_id, keyword_init: true)

  def self.resolve!(author:, params:, visibility:)
    new(author, params, visibility).resolve!
  end

  def initialize(author, params, visibility)
    @author = author
    @params = params
    @visibility = visibility.to_s
  end

  def resolve!
    local = PostingIdentity::LocalGroupPost.decision(author: @author, account_id: @params[:posting_context_account_id])
    return local_outcome(local) if local.group

    PostingIdentity::RemoteGroupPost.authorize!(author: @author, params: @params, visibility: @visibility)
  end

  private

  def local_outcome(decision)
    raise rejected if @params[:audience_account_id].present?
    raise rejected unless decision.can_post

    assert_current_context!(decision.context)
    raise rejected unless allowed_visibility?(decision.context)

    accounts = local_mention_accounts(decision)
    assert_local_mentions!(accounts, decision.group)
    Outcome.new(allowed_mentions: accounts.map(&:id), audience_account_id: nil)
  end

  def assert_current_context!(context)
    raise rejected if context.nil?
    raise rejected unless @params[:posting_context_key].to_s == context[:key].to_s
    raise rejected unless @params[:posting_context_revision].to_s == context.dig(:source, :revision).to_s
  end

  def allowed_visibility?(context)
    Array(context.dig(:constraints, :allowed_visibilities)).map(&:to_s).include?(@visibility)
  end

  def local_mention_accounts(decision)
    ids = Array(decision.context.dig(:managed, :mentions)).filter_map { |mention| mention[:account_id].presence }.uniq
    accounts = Account.where(id: ids).to_a
    raise rejected unless accounts.map { |account| account.id.to_s }.sort == ids.map(&:to_s).sort

    (accounts + [@author]).uniq
  end

  def assert_local_mentions!(accounts, group)
    body = tokens(@params[:status])
    warning = tokens(@params[:spoiler_text])
    raise mention_rejected if (body + warning).any? { |token| !allowed_token?(token, accounts) }
    raise mention_rejected unless body.any? { |token| allowed_token?(token, [group]) }
  end

  def tokens(text)
    text.to_s.scan(Account::MENTION_RE).map { |match| match.first.to_s }
  end

  def allowed_token?(token, accounts)
    username, domain = token.split('@', 2)
    domain = nil if domain.blank? || TagManager.instance.local_domain?(domain)
    accounts.any? do |account|
      next false unless account.username.casecmp(username).zero?

      domain.nil? ? account.domain.blank? : account.domain.to_s.casecmp(domain).zero?
    end
  end

  def rejected
    Mastodon::ValidationError.new(I18n.t('posting_identity_links.delegated_group_rejected'))
  end

  def mention_rejected
    Mastodon::ValidationError.new(I18n.t('posting_identity_links.delegated_group_mention_rejected'))
  end
end
