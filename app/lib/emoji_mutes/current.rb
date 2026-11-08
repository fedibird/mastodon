# frozen_string_literal: true

# Request-local memo for mute rules, the collection revision, and a page of
# legacy reaction breakdowns. Nothing here is written back to a status.
class EmojiMutes::Current < ActiveSupport::CurrentAttributes
  attribute :rule_sets, :revisions, :breakdowns, :breakdown_account_id

  def self.forget(account_id)
    rule_sets&.delete(account_id)
    revisions&.delete(account_id)
    return unless breakdown_account_id == account_id

    self.breakdowns = nil
    self.breakdown_account_id = nil
  end
end
