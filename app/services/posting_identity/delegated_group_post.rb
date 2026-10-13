# frozen_string_literal: true

# A delegated group post keeps the local Fedibird group rules. The client
# account id and context key are resolved again here. They are not permission
# by themselves. The returned ids are the only mentions ProcessMentionsService
# may attach.
class PostingIdentity::DelegatedGroupPost
  def self.resolve!(author:, params:, visibility:)
    new(author, params, visibility).resolve!
  end

  def initialize(author, params, visibility)
    @author = author
    @params = params
    @visibility = visibility.to_s
  end

  def resolve!
    decision = PostingIdentity::LocalGroupPost.decision(author: @author, account_id: @params[:posting_context_account_id])
    raise rejected unless decision.can_post && decision.group

    assert_current_context!(decision.context)
    raise rejected unless allowed_visibility?(decision.context)

    accounts = mention_accounts(decision)
    assert_mentions!(accounts, decision.group)
    accounts.map(&:id)
  end

  private

  def assert_current_context!(context)
    raise rejected if context.nil?
    raise rejected unless @params[:posting_context_key].to_s == context[:key].to_s
    raise rejected unless @params[:posting_context_revision].to_s == context.dig(:source, :revision).to_s
  end

  def allowed_visibility?(context)
    Array(context.dig(:constraints, :allowed_visibilities)).map(&:to_s).include?(@visibility)
  end

  def mention_accounts(decision)
    ids = Array(decision.context.dig(:managed, :mentions)).filter_map { |mention| mention[:account_id].presence }.uniq
    accounts = Account.where(id: ids).to_a
    raise rejected unless accounts.map { |account| account.id.to_s }.sort == ids.map(&:to_s).sort

    (accounts + [@author]).uniq
  end

  def assert_mentions!(accounts, group)
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
