# frozen_string_literal: true

# Names for places already stored on this server. Group lookup reads Account
# rows by id. List lookup is limited to lists owned by this user. Neither
# path starts Discovery, WebFinger, or remote account resolution.
class UserPostingContextAssignment::PlaceCatalog
  def self.for(user, assignments)
    rows = Array(assignments)
    group_ids = rows.select { |row| row.surface_kind == 'group' }.map(&:surface_key)
    list_ids = rows.select { |row| row.surface_kind == 'list' }.map(&:surface_key)
    accounts = group_ids.empty? ? {} : Account.where(id: group_ids).index_by { |account| account.id.to_s }
    lists = if list_ids.empty? || user.nil? || user.account_id.nil?
              {}
            else
              List.where(id: list_ids, account_id: user.account_id).index_by { |list| list.id.to_s }
            end
    new(accounts, lists)
  end

  def initialize(accounts, lists)
    @accounts = accounts
    @lists = lists
  end

  def label(assignment)
    case assignment.surface_kind
    when 'group'
      account = @accounts[assignment.surface_key.to_s]
      return account.acct if account&.group?

      I18n.t('user_posting_context_assignments.missing_group', id: assignment.surface_key)
    when 'hashtag'
      key = assignment.surface_key.to_s
      return I18n.t('user_posting_context_assignments.missing_hashtag', id: key) if key.blank?

      "##{key}"
    when 'list'
      list = @lists[assignment.surface_key.to_s]
      return list.title if list

      I18n.t('user_posting_context_assignments.missing_list', id: assignment.surface_key)
    else
      I18n.t('user_posting_context_assignments.missing_place', id: assignment.surface_key)
    end
  end

  def place_available?(assignment)
    case assignment.surface_kind
    when 'group'
      @accounts[assignment.surface_key.to_s]&.group? || false
    when 'hashtag'
      assignment.surface_key.present?
    when 'list'
      @lists[assignment.surface_key.to_s].present?
    else
      false
    end
  end
end
