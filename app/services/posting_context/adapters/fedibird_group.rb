# frozen_string_literal: true

class PostingContext::Adapters::FedibirdGroup
  def self.applicable?(account)
    account.group? && account.local? && account.id.present?
  end

  def self.context(account)
    account_id = account.id.to_s

    {
      key: "builtin:fedibird-group:#{account_id}",
      source: {
        id: 'builtin:fedibird-group',
        revision: 1,
      },
      managed: {
        hashtags: [],
        mentions: [
          mention(account_id, account.acct, 'group-account-mention'),
        ],
      },
      requirements: {
        following_accounts: [
          mention(account_id, account.acct, 'group-follow'),
        ],
      },
      constraints: {
        allowed_visibilities: %w(public unlisted),
      },
    }
  end

  def self.mechanism
    'built_in'
  end

  def self.adapter_name
    'fedibird_group'
  end

  def self.authority
    'server'
  end

  def self.mention(account_id, acct, rule_id)
    {
      account_id: account_id,
      acct: acct,
      enforcement: 'required',
      rule_id: rule_id,
    }
  end

  private_class_method :mention
end
