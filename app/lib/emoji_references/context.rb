# frozen_string_literal: true

# Optional status/account context. Visibility uses the same read checks as
# the existing status and account APIs and never returns those records.
class EmojiReferences::Context
  FIELDS = %w(status_id account_id).freeze

  def initialize(user)
    @user = user
  end

  def authorize!(context)
    return if context.nil?
    invalid!('context', 'invalid_type') unless context.is_a?(Hash)
    invalid!('context', 'unknown_field') unless (context.keys - FIELDS).empty?
    invalid!('context', 'invalid_reference') if context.empty?

    authorize_status!(context['status_id']) if context.key?('status_id')
    authorize_account!(context['account_id']) if context.key?('account_id')
  end

  private

  def authorize_status!(raw_id)
    status = Status.include_expired.find(database_id!(raw_id, 'context.status_id'))
    hidden = status.ap_page? || ExternalBridge::ProjectionPrivacy.hidden_from?(status, @user.id)
    raise EmojiReferences::NotFound if hidden
    raise EmojiReferences::NotFound unless StatusPolicy.new(@user.account, status).show?
  rescue ActiveRecord::RecordNotFound
    raise EmojiReferences::NotFound
  end

  def authorize_account!(raw_id)
    account = Account.find(database_id!(raw_id, 'context.account_id'))
    viewer = @user.account
    raise EmojiReferences::NotFound if account.suspended?
    raise EmojiReferences::NotFound unless Account.without_unapproved.exists?(id: account.id)
    raise EmojiReferences::NotFound if viewer.blocking?(account) || account.blocking?(viewer)
    raise EmojiReferences::NotFound if account.domain.present? && viewer.domain_blocking?(account.domain)
  rescue ActiveRecord::RecordNotFound
    raise EmojiReferences::NotFound
  end

  def database_id!(value, path)
    valid = value.is_a?(String) && PersonalEmojiSets::Definition::DATABASE_ID_PATTERN.match?(value) && value.to_i <= PersonalEmojiSets::Definition::MAX_DATABASE_ID
    invalid!(path, 'invalid_id') unless valid
    value
  end

  def invalid!(path, code)
    raise EmojiReferences::Invalid.new(path, code)
  end
end
