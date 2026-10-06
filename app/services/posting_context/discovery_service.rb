# frozen_string_literal: true

class PostingContext::DiscoveryService
  SCHEMA_VERSION = 1

  # Ordered from most authoritative to the neutral fallback.
  # P10 only has the local Fedibird Group adapter. Further adapters
  # belong in this list, ahead of the unsupported result.
  ADAPTERS = [
    PostingContext::Adapters::FedibirdGroup,
  ].freeze

  def call(account)
    return not_applicable(account, 'not_group') unless account.group?

    adapter = ADAPTERS.find { |candidate| candidate.applicable?(account) }

    return unsupported(account, 'no_supported_adapter') if adapter.nil?

    resolved(account, adapter)
  end

  private

  def resolved(account, adapter)
    {
      schema_version: SCHEMA_VERSION,
      account_id: account.id.to_s,
      status: 'resolved',
      context: adapter.context(account),
      discovery: {
        mechanism: adapter.mechanism,
        adapter: adapter.adapter_name,
        authority: adapter.authority,
      },
    }
  end

  def unsupported(account, reason)
    neutral(account, 'unsupported', reason)
  end

  def not_applicable(account, reason)
    neutral(account, 'not_applicable', reason)
  end

  def neutral(account, status, reason)
    {
      schema_version: SCHEMA_VERSION,
      account_id: account.id.to_s,
      status: status,
      reason: reason,
      context: nil,
      discovery: {
        mechanism: nil,
        adapter: nil,
        authority: nil,
      },
    }
  end
end
