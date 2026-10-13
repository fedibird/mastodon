# frozen_string_literal: true

# A delegated post is published as the granting account. New public,
# unlisted, and followers-only posts need post. A reply also needs reply,
# a quote also needs quote, and a local group post also needs group.
# Still images also need media. Polls, schedules, and remote groups stay
# out. The check runs after the sender is fixed and before the status is saved.
class PostingIdentity::DelegatedTextPost
  ALLOWED_VISIBILITIES = %w(public unlisted private).freeze
  QUOTE_VISIBILITIES = %w(public unlisted).freeze
  VISIBILITY_RANK = { 'public' => 0, 'unlisted' => 1, 'private' => 2 }.freeze
  QT_PATTERN = /QT:\s*\[\s*(https:\/\/.+?)\s*\]/i
  QT_MARKUP = /QT:\s*\[.*?\]/i

  Result = Struct.new(:text, :thread, :quote_id, :allowed_mentions, :audience_account_id, keyword_init: true)

  def self.resolve!(resolution:, viewer:, params:)
    new(resolution, viewer, params).resolve!
  end

  def self.resolved_visibility(resolution, params)
    params[:visibility].presence || resolution.account.user&.setting_default_privacy.presence || 'public'
  end

  def initialize(resolution, viewer, params)
    @resolution = resolution
    @viewer = viewer
    @params = params
  end

  def resolve!
    raise Mastodon::NotPermittedError unless @resolution&.delegated?

    permit!('post')
    permit!('media') if media_requested?
    raise unsupported if unsupported_shape?

    if group_requested?
      permit!('group')
      raise group_rejected if reply_requested? || quote_requested?

      group = PostingIdentity::DelegatedGroupPost.resolve!(
        author: author,
        params: @params,
        visibility: requested_visibility
      )
      return Result.new(
        text: stripped_text,
        thread: nil,
        quote_id: nil,
        allowed_mentions: group.allowed_mentions,
        audience_account_id: group.audience_account_id
      )
    end

    raise unsupported unless self.class::ALLOWED_VISIBILITIES.include?(requested_visibility)

    permit!('reply') if reply_requested?
    permit!('quote') if quote_requested?
    # A reply allows a closed set of mentions. A quote allows none.
    # Doing both in one post would let one path bypass the other.
    raise unsupported if reply_requested? && quote_requested?
    raise mention_rejected if quote_requested? && marked_mention?
    raise unsupported if plain_post? && marked_mention?

    thread = reply_requested? ? resolve_reply! : nil
    quote = quote_requested? ? resolve_quote! : nil

    Result.new(
      text: stripped_text,
      thread: thread,
      quote_id: quote&.id,
      allowed_mentions: mention_boundary(thread, quote),
      audience_account_id: nil
    )
  end

  private

  def author
    @resolution.account
  end

  def permit!(operation)
    raise Mastodon::NotPermittedError unless PostingIdentity::DelegationResolver.grant_permits?(
      grantee: @resolution.delegation.grantee_user,
      delegation: @resolution.delegation,
      operation: operation
    )
  end

  def requested_visibility
    self.class.resolved_visibility(@resolution, @params).to_s
  end

  def unsupported
    Mastodon::ValidationError.new(I18n.t('posting_identity_links.delegated_unsupported'))
  end

  def interaction_rejected
    Mastodon::ValidationError.new(I18n.t('posting_identity_links.delegated_interaction_rejected'))
  end

  def mention_rejected
    Mastodon::ValidationError.new(I18n.t('posting_identity_links.delegated_mention_rejected'))
  end

  def group_rejected
    Mastodon::ValidationError.new(I18n.t('posting_identity_links.delegated_group_rejected'))
  end

  def group_requested?
    present?(@params[:posting_context_account_id]) ||
      present?(@params[:posting_context_key]) ||
      present?(@params[:posting_context_revision])
  end

  def concealed!
    raise ActiveRecord::RecordNotFound
  end

  def unsupported_shape?
    present?(@params[:circle_id]) ||
      (present?(@params[:audience_account_id]) && !group_requested?) ||
      present?(@params[:poll]) ||
      present?(@params[:scheduled_at]) ||
      present?(@params[:scheduled_in]) ||
      present?(@params[:expires_at]) ||
      present?(@params[:expires_in]) ||
      present?(@params[:status_reference_ids]) ||
      present?(@params[:status_reference_urls]) ||
      present?(@params[:allowed_mentions]) ||
      quote_urls.size > 1
  end

  def reply_requested?
    present?(@params[:in_reply_to_id])
  end

  def quote_requested?
    present?(@params[:quote_id]) || quote_urls.any?
  end

  def plain_post?
    !reply_requested? && !quote_requested?
  end

  def media_requested?
    present?(@params[:media_ids])
  end

  def resolve_reply!
    status = load_status(@params[:in_reply_to_id])
    target = authorize_target!(status)
    raise interaction_rejected unless reply_visibility_allowed?(target)

    assert_mentions_allowed!(target)
    target
  end

  def resolve_quote!
    quoted = authorize_target!(load_status(@params[:quote_id])) if present?(@params[:quote_id])
    linked = quote_urls.map { |url| authorize_target!(status_from_quote_url(url)) }
    targets = [quoted, *linked].compact
    concealed! if targets.empty?
    raise interaction_rejected unless targets.map(&:id).uniq.one?
    raise interaction_rejected unless self.class::QUOTE_VISIBILITIES.include?(targets.first.visibility)

    targets.first
  end

  def load_status(id)
    concealed! unless id.to_s.match?(/\A[1-9]\d*\z/)

    status = Status.find_by(id: id)
    concealed! if status.nil?

    status
  end

  def status_from_quote_url(url)
    resolved = ResolveURLService.new.call(url, on_behalf_of: author)
    concealed! unless resolved.is_a?(Status)

    resolved
  rescue HTTP::Error, OpenSSL::SSL::SSLError, Mastodon::UnexpectedResponseError, Addressable::URI::InvalidURIError
    concealed!
  end

  def authorize_target!(status)
    concealed! if status.nil?

    original = status.reblog? ? status.reblog : status
    concealed! if original.nil?

    [status, original].uniq.each do |item|
      concealed! unless visible_to?(@viewer, item) && usable_by?(author, item)
    end
    raise interaction_rejected if original.account&.group? || original.audience_account_id.present?

    original
  end

  def visible_to?(account, status)
    account.present? && StatusPolicy.new(account, status).show?
  end

  def usable_by?(account, status)
    return false unless visible_to?(account, status)
    return false if account.blocking?(status.account) || account.muting?(status.account)
    return false if status.conversation_id.present? && account.muting_conversation?(status.conversation)

    true
  end

  def reply_visibility_allowed?(status)
    parent = status.visibility.to_s
    requested = requested_visibility
    return false unless self.class::ALLOWED_VISIBILITIES.include?(parent)
    return false unless self.class::VISIBILITY_RANK.key?(requested)

    self.class::VISIBILITY_RANK.fetch(requested) >= self.class::VISIBILITY_RANK.fetch(parent)
  end

  def assert_mentions_allowed!(thread)
    allowed = mention_accounts(thread)
    tokens = mention_tokens(@params[:status]) + mention_tokens(@params[:spoiler_text])
    raise mention_rejected if tokens.any? { |token| !mention_allowed?(token, allowed) }
  end

  def allowed_mention_ids(thread)
    mention_accounts(thread).map(&:id)
  end

  # nil skips the mention boundary. A quote passes an empty list so a
  # mention resolved by ProcessMentionsService is still rejected.
  def mention_boundary(thread, quote)
    return allowed_mention_ids(thread) if thread
    return [] if quote

    nil
  end

  def mention_accounts(thread)
    accounts = [thread.account, author]
    thread.mentions.includes(:account).to_a.each do |mention|
      next if mention.silent? || mention.account.nil?
      next if mention.account.suspended? || mention.account.group?

      accounts << mention.account
    end
    accounts.uniq
  end

  def mention_tokens(text)
    text.to_s.scan(Account::MENTION_RE).map { |match| match.first.to_s }
  end

  def mention_allowed?(token, accounts)
    username, domain = token.split('@', 2)
    domain = nil if domain.blank? || TagManager.instance.local_domain?(domain)
    accounts.any? do |account|
      next false unless account.username.casecmp(username).zero?

      if domain.nil?
        account.domain.blank?
      else
        account.domain.to_s.casecmp(domain).zero?
      end
    end
  end

  def marked_mention?
    mention_tokens(@params[:status]).any? || mention_tokens(@params[:spoiler_text]).any?
  end

  def quote_urls
    [@params[:status], @params[:spoiler_text]].flat_map { |text| text.to_s.scan(QT_PATTERN).flatten }
  end

  def stripped_text
    @params[:status].to_s.sub(QT_MARKUP, '')
  end

  def present?(value)
    case value
    when nil
      false
    when String
      value.present?
    when Array
      value.any? { |item| present?(item) }
    when ActionController::Parameters, Hash
      value.values.any? { |item| present?(item) }
    else
      value.respond_to?(:present?) ? value.present? : !value.nil?
    end
  end
end
