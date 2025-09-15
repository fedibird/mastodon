# frozen_string_literal: true

class REST::CompactStatusesSerializer < ActiveModel::Serializer
  attribute :statuses
  attribute :referenced_statuses
  attribute :accounts
  attribute :relationships

  def current_user?
    !current_user.nil?
  end

  def statuses
    object.statuses.map do |status|
      REST::StatusSerializer.new(status, root: false, relationships: status_relationships, account_relationships: account_relationships, application_name: instance_options[:application_name], compact: true, scope: current_user, scope_name: :current_user)
    end || []
  end

  def referenced_statuses
    Status.where(id: referenced_status_ids).map do |status|
      REST::StatusSerializer.new(status, root: false, relationships: status_relationships, account_relationships: account_relationships, application_name: instance_options[:application_name], compact: true, scope: current_user, scope_name: :current_user)
    end || []
  end

  def accounts
    source_accounts.map do |account|
      REST::AccountSerializer.new(account, root: false, scope: current_user, scope_name: :current_user)
    end || []
  end

  def relationships
    return [] unless current_user?

    source_accounts.map do |account|
      REST::RelationshipSerializer.new(account, root: false, relationships: account_relationships, scope: current_user, scope_name: :current_user)
    end || []
  end

  def referenced_status_ids
    @referenced_status_ids ||= object.statuses.flat_map { |status| [status.reblog_of_id, status.quote_id, status.reblog&.quote_id] }.compact.uniq - object.statuses.pluck(:id)
  end

  def source_accounts
    @source_accounts ||= Account.where(id: source_accounts_ids)
  end

  def source_accounts_ids
    @source_accounts_ids ||= object.statuses.flat_map(&:account_ids).uniq
  end

  def status_relationships
    @status_relationships ||= StatusRelationshipsPresenter.new(object.statuses, current_user&.account_id)
  end

  def account_relationships
    @account_relationships ||= AccountRelationshipsPresenter.new(source_accounts_ids, current_user&.account_id)
  end
end
