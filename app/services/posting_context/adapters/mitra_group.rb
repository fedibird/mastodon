# frozen_string_literal: true

class PostingContext::Adapters::MitraGroup
  def self.applicable?(account)
    account.group? &&
      !account.local? &&
      account.activitypub? &&
      account.id.present? &&
      account.uri.present? &&
      account.inbox_url.present? &&
      mitra?(account.node)
  end

  def self.context(account)
    account_id = account.id.to_s

    {
      key: "protocol:fep-1b12-group:#{account_id}",
      source: {
        id: 'compat:mitra-fep-1b12',
        revision: 1,
      },
      managed: {
        hashtags: [],
        mentions: [],
      },
      requirements: {
        following_accounts: [],
      },
      constraints: {
        allowed_visibilities: %w(public unlisted),
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
    'mitra_group'
  end

  def self.authority
    'compatibility'
  end

  def self.mitra?(node)
    node.present? && node.software_name.to_s.casecmp('mitra').zero?
  end

  private_class_method :mitra?
end
