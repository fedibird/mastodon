# frozen_string_literal: true

# One-query index of account-migration Action Review rows for the migrations
# currently being rendered. Newest id wins. Other operations are ignored.
class AccountMigration::ReviewLookup
  def self.for_migrations(migrations)
    ids = Array(migrations).map(&:id).compact
    return {} if ids.empty?

    ActionReviewRequest
      .where(operation_type: 'account_migration', resource_type: 'AccountMigration', resource_id: ids)
      .order(id: :desc)
      .each_with_object({}) { |request, index| index[request.resource_id] ||= request }
  end
end
