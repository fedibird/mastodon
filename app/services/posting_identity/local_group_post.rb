# frozen_string_literal: true

# Whether the posting account can publish to one local Fedibird group.
# The rules are the built-in group context and the same follow check the
# local group distribution already uses. A missing or remote group is not
# a permission to post somewhere else.
class PostingIdentity::LocalGroupPost
  Decision = Struct.new(:group, :context, :can_post, :following, keyword_init: true)

  def self.decision(author:, account_id:)
    group = local_group(account_id)
    return empty unless group

    context = PostingContext::Adapters::FedibirdGroup.context(group)
    following = author.present? && author.following?(group)
    Decision.new(
      group: group,
      context: context,
      following: following,
      can_post: following && accepting?(group)
    )
  end

  def self.empty
    Decision.new(group: nil, context: nil, can_post: false, following: false)
  end

  def self.local_group(account_id)
    token = account_id.to_s
    return nil unless token.match?(/\A[1-9]\d*\z/)

    account = Account.find_by(id: token)
    return nil if account.nil? || account.suspended?
    return nil unless PostingContext::Adapters::FedibirdGroup.applicable?(account)

    account
  end

  # A group account without a user can still receive a local mention.
  # A disabled user can no longer accept one.
  def self.accepting?(group)
    user = group.user
    user.nil? || user.functional?
  end

  private_class_method :empty, :local_group, :accepting?
end
