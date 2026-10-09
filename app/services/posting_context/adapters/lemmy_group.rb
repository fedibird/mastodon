# frozen_string_literal: true

class PostingContext::Adapters::LemmyGroup
  def self.applicable?(account)
    account.group? &&
      !account.local? &&
      account.activitypub? &&
      account.id.present? &&
      account.uri.present? &&
      account.inbox_url.present? &&
      lemmy?(account.node)
  end

  def self.context(account)
    account_id = account.id.to_s

    {
      key: "protocol:fep-1b12-lemmy:#{account_id}",
      source: {
        id: 'compat:lemmy-group-note',
        revision: 1,
      },
      managed: {
        hashtags: [],
        mentions: [
          mention(account_id, account.acct, 'lemmy-group-mention'),
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
    'lemmy_group'
  end

  def self.authority
    'compatibility'
  end

  def self.lemmy?(node)
    node.present? && node.software_name.to_s.casecmp('lemmy').zero?
  end

  def self.mention(account_id, acct, rule_id)
    {
      account_id: account_id,
      acct: acct,
      enforcement: 'required',
      rule_id: rule_id,
      placement: 'after_title',
    }
  end

  private_class_method :lemmy?, :mention
end
