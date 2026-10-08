# frozen_string_literal: true

class PostingContext::Adapters::PiefedGroup
  def self.applicable?(account)
    account.group? &&
      !account.local? &&
      account.activitypub? &&
      account.id.present? &&
      account.uri.present? &&
      account.inbox_url.present? &&
      piefed?(account.node)
  end

  def self.context(account)
    account_id = account.id.to_s

    {
      key: "protocol:fep-1b12-piefed:#{account_id}",
      source: {
        id: 'compat:piefed-group-note',
        revision: 1,
      },
      managed: {
        hashtags: [],
        mentions: [
          mention(account_id, account.acct, 'piefed-group-mention'),
        ],
      },
      requirements: {
        following_accounts: [],
      },
      constraints: {
        allowed_visibilities: %w(public),
      },
      protocol: {
        activitypub: {
          audience: {
            account_id: account_id,
            acct: account.acct,
            enforcement: 'required',
            rule_id: 'fep-1b12-group-audience',
          },
        },
      },
    }
  end

  def self.mechanism
    'nodeinfo_software'
  end

  def self.adapter_name
    'piefed_group'
  end

  def self.authority
    'compatibility'
  end

  def self.piefed?(node)
    node.present? && node.software_name.to_s.casecmp('piefed').zero?
  end

  def self.mention(account_id, acct, rule_id)
    {
      account_id: account_id,
      acct: acct,
      enforcement: 'required',
      rule_id: rule_id,
      placement: 'append',
    }
  end

  private_class_method :piefed?, :mention
end
