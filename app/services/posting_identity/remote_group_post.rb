# frozen_string_literal: true

# Whether delegated account B may address one remote ActivityPub group.
# Permission comes from the existing FEP-5219 resolvers for B. Mitra
# posts with FEP-1b12 audience and no group mention. A NodeBB category
# uses that audience plus a required category mention in the body.
# The topic collection from FEP-7888 is not derived from the audience.
class PostingIdentity::RemoteGroupPost
  ADAPTERS = {
    'mitra_group' => {
      source_id: 'compat:mitra-fep-1b12',
      key_prefix: 'protocol:fep-1b12-group:',
      revision: '1',
      visibilities: %w(public unlisted).freeze,
      body_mention: false,
    }.freeze,
    'nodebb_group' => {
      source_id: 'compat:nodebb-fep-1b12',
      key_prefix: 'protocol:fep-1b12-nodebb:',
      revision: '1',
      visibilities: %w(public).freeze,
      body_mention: true,
    }.freeze,
  }.freeze
  SUPPORTED_ADAPTERS = ADAPTERS.keys.freeze
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
    supported = contract_matches?(discovered, group, adapter)
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
    assert_mentions!(params, accounts, current)
    assert_resolved_mentions!(params, accounts, current)
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

  def contract_matches?(discovered, group, adapter)
    contract = ADAPTERS[adapter]
    context = discovered[:context]
    return false unless discovered[:status] == 'resolved' && contract && context
    return false if group.inbox_url.blank?

    context[:key].to_s == "#{contract[:key_prefix]}#{group.id}" &&
      context.dig(:source, :id).to_s == contract[:source_id] &&
      context.dig(:source, :revision).to_s == contract[:revision] &&
      context.dig(:protocol, :activitypub, :audience, :account_id).to_s == group.id.to_s &&
      Array(context.dig(:constraints, :allowed_visibilities)).map(&:to_s) == contract[:visibilities] &&
      mention_contract?(context, group, contract)
  end

  def mention_contract?(context, group, contract)
    mentions = Array(context.dig(:managed, :mentions))
    return mentions.empty? unless contract[:body_mention]

    mentions.one? &&
      mentions.first[:account_id].to_s == group.id.to_s &&
      mentions.first[:acct].to_s == group.acct &&
      mentions.first[:enforcement].to_s == 'required'
  end

  def assert_context!(current, params, visibility)
    context = current.context
    contract = ADAPTERS.fetch(current.delivery_adapter)
    audience_id = context.dig(:protocol, :activitypub, :audience, :account_id).to_s
    raise rejected unless contract_matches?({ status: 'resolved', context: context }, current.group, current.delivery_adapter)
    raise rejected unless params[:posting_context_key].to_s == context[:key].to_s
    raise rejected unless params[:posting_context_revision].to_s == context.dig(:source, :revision).to_s
    raise rejected unless audience_id == current.group.id.to_s
    raise rejected unless params[:posting_context_account_id].to_s == current.group.id.to_s
    raise rejected unless params[:audience_account_id].to_s == current.group.id.to_s
    raise rejected unless contract[:visibilities].include?(visibility.to_s)
  end

  def mention_accounts(current)
    ids = Array(current.context.dig(:managed, :mentions)).filter_map { |mention| mention[:account_id].presence }.uniq
    accounts = Account.where(id: ids).to_a
    raise rejected unless accounts.map { |account| account.id.to_s }.sort == ids.map(&:to_s).sort

    accounts
  end

  def assert_mentions!(params, accounts, current)
    body = tokens(params[:status])
    warning = tokens(params[:spoiler_text])
    raise mention_rejected if (body + warning).any? { |token| !allowed_token?(token, accounts) }
    return unless ADAPTERS.fetch(current.delivery_adapter)[:body_mention]

    accounts.each do |account|
      raise mention_rejected unless body.any? { |token| allowed_token?(token, [account]) }
    end
  end

  # The text check is not enough: the mention has to resolve to the
  # category account ProcessMentionsService will actually deliver.
  def assert_resolved_mentions!(params, accounts, current)
    return unless ADAPTERS.fetch(current.delivery_adapter)[:body_mention]

    draft = Status.new(account: @author, text: params[:status].to_s, visibility: :public)
    resolved = ProcessMentionsService.new.prepare(draft, nil, silent_audience: false)
    resolved_ids = Array(resolved).map(&:account_id)
    raise mention_rejected unless accounts.all? { |account| resolved_ids.include?(account.id) }
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
