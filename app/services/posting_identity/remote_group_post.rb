# frozen_string_literal: true

# Whether delegated account B may address one remote ActivityPub group.
# Permission comes from the existing FEP-5219 resolvers for B. Delivery
# in this stage is Mitra's FEP-1b12 audience path. Another adapter can
# be named later without turning unknown evidence into a post.
class PostingIdentity::RemoteGroupPost
  SUPPORTED_ADAPTERS = %w(mitra_group).freeze
  Outcome = Struct.new(:allowed_mentions, :audience_account_id, keyword_init: true)

  Decision = Struct.new(
    :group,
    :context,
    :can_post,
    :permission_status,
    :permission_confirmed,
    :permission_source,
    :permission_freshness,
    :delivery_status,
    :delivery_adapter,
    :delivery_authority,
    keyword_init: true
  )

  def self.decision(author:, account_id:)
    new(author, account_id).decision
  end

  def self.authorize!(author:, params:, visibility:)
    new(author, params[:posting_context_account_id]).authorize!(params, visibility)
  end

  def initialize(author, account_id)
    @author = author
    @account_id = account_id
  end

  def decision
    group = remote_group
    return empty unless group

    discovered = PostingContext::DiscoveryService.new.call(group, viewer: nil)
    adapter = discovered.dig(:discovery, :adapter).to_s
    supported = discovered[:status] == 'resolved' && SUPPORTED_ADAPTERS.include?(adapter)
    permission = create_permission(group)
    Decision.new(
      group: group,
      context: discovered[:context],
      can_post: supported && permission[:confirmed],
      permission_status: permission[:status],
      permission_confirmed: permission[:confirmed],
      permission_source: permission[:source],
      permission_freshness: permission[:freshness],
      delivery_status: supported ? 'supported' : 'unsupported',
      delivery_adapter: adapter.presence,
      delivery_authority: discovered.dig(:discovery, :authority)
    )
  end

  def authorize!(params, visibility)
    current = decision
    raise rejected unless current.can_post && current.group && current.context

    assert_context!(current, params, visibility)
    accounts = mention_accounts(current)
    assert_mentions!(params, accounts)
    Outcome.new(allowed_mentions: accounts.map(&:id), audience_account_id: current.group.id)
  end

  private

  def remote_group
    token = @account_id.to_s
    return nil unless token.match?(/\A[1-9]\d*\z/)

    account = Account.find_by(id: token)
    return nil if account.nil? || account.suspended? || account.local?
    return nil unless account.activitypub? && account.group?

    account
  end

  def empty
    Decision.new(
      group: nil,
      context: nil,
      can_post: false,
      permission_status: 'unknown',
      permission_confirmed: false,
      permission_source: PostingContext::GroupPermissionEvidenceResolver::SOURCE,
      permission_freshness: 'absent',
      delivery_status: 'unsupported',
      delivery_adapter: nil,
      delivery_authority: nil
    )
  end

  def create_permission(group)
    affiliations = PostingContext::GroupAffiliationEvidenceResolver.new.call(group, @author)
    definitions = PostingContext::GroupPermissionDefinitionResolver.new.call(group)
    create = PostingContext::GroupPermissionEvidenceResolver.new.call(affiliations, definitions)[:create]
    confirmed = create[:status] == 'allowed'
    {
      status: confirmed ? 'allowed' : 'unknown',
      confirmed: confirmed,
      source: create[:source],
      freshness: freshness(affiliations, definitions, confirmed),
    }
  end

  def freshness(affiliations, definitions, confirmed)
    statuses = [affiliations[:snapshot_status], definitions[:snapshot_status]]
    return 'stale' if statuses.include?('stale')
    return 'current' if confirmed

    'absent'
  end

  def assert_context!(current, params, visibility)
    context = current.context
    audience_id = context.dig(:protocol, :activitypub, :audience, :account_id).to_s
    allowed = Array(context.dig(:constraints, :allowed_visibilities)).map(&:to_s)
    raise rejected unless params[:posting_context_key].to_s == context[:key].to_s
    raise rejected unless params[:posting_context_revision].to_s == context.dig(:source, :revision).to_s
    raise rejected unless audience_id == current.group.id.to_s
    raise rejected unless params[:posting_context_account_id].to_s == current.group.id.to_s
    raise rejected unless params[:audience_account_id].to_s == current.group.id.to_s
    raise rejected unless allowed.include?(visibility.to_s)
  end

  def mention_accounts(current)
    ids = Array(current.context.dig(:managed, :mentions)).filter_map { |mention| mention[:account_id].presence }.uniq
    accounts = Account.where(id: ids).to_a
    raise rejected unless accounts.map { |account| account.id.to_s }.sort == ids.map(&:to_s).sort

    accounts
  end

  def assert_mentions!(params, accounts)
    body = tokens(params[:status])
    warning = tokens(params[:spoiler_text])
    raise mention_rejected if (body + warning).any? { |token| !allowed_token?(token, accounts) }

    accounts.each do |account|
      raise mention_rejected unless body.any? { |token| allowed_token?(token, [account]) }
    end
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
