# frozen_string_literal: true

# The only write path for group directory languages.
#
# #657's creation request stays an immutable review snapshot and has no
# language column. There is no public settings screen here: the group editor
# from that work should call replace!. Until then, a server administrator or
# the active local owner can store tags through this method. Remote groups
# are refused so a missing NodeInfo language is never saved as a guess.
class GroupDirectory::Languages
  MAX_TAGS = 8
  MAX_LENGTH = 35
  PATTERN = /\A[a-z]{2,3}(?:-[0-9A-Za-z]{2,8}){0,3}\z/

  def self.canonicalize(value)
    parts = value.to_s.strip.split('-')
    return if parts.empty? || parts.any?(&:blank?)

    parts = parts.each_with_index.map do |part, index|
      if index.zero?
        part.downcase
      elsif part.match?(/\A[a-zA-Z]{4}\z/)
        part.capitalize
      elsif part.match?(/\A(?:[a-zA-Z]{2}|[0-9]{3})\z/)
        part.upcase
      else
        part.downcase
      end
    end
    tag = parts.join('-')
    tag if tag.length <= MAX_LENGTH && PATTERN.match?(tag)
  end

  def self.normalize(tags)
    raise Mastodon::ValidationError unless tags.is_a?(Array)
    raise Mastodon::ValidationError if tags.size > MAX_TAGS

    canonical = tags.map { |tag| canonicalize(tag.to_s) }
    raise Mastodon::ValidationError if canonical.any?(&:nil?)

    canonical.uniq
  end

  def self.replace!(account:, tags:, actor:)
    canonical = normalize(tags)
    raise Mastodon::NotPermittedError unless allowed?(account, actor)

    Account.transaction do
      account.lock!
      raise Mastodon::NotPermittedError unless allowed?(account, actor)

      GroupLanguage.where(account_id: account.id).delete_all
      canonical.each do |tag|
        GroupLanguage.create!(account_id: account.id, tag: tag)
      end
    end

    canonical
  end

  def self.allowed?(account, actor)
    return false unless account&.local? && account&.group?
    return false unless GroupManagement.local_functional_person?(actor)
    return true if GroupManagement.server_administrator?(actor)

    GroupRoleAssignment.active.owner.exists?(group_account_id: account.id, member_account_id: actor.id)
  end
end
