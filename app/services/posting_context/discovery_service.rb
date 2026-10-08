# frozen_string_literal: true

class PostingContext::DiscoveryService
  SCHEMA_VERSION = 1

  # Ordered from most authoritative to the neutral fallback.
  # Built-in rules come first. An explicit protocol adapter, once one
  # exists, belongs ahead of NodeInfo software heuristics. This pass
  # does not infer that evidence. NodeInfo adapters stay in this order:
  # Mitra, then NodeBB, then Lemmy, then PieFed.
  ADAPTERS = [
    PostingContext::Adapters::FedibirdGroup,
    PostingContext::Adapters::MitraGroup,
    PostingContext::Adapters::NodebbGroup,
    PostingContext::Adapters::LemmyGroup,
    PostingContext::Adapters::PiefedGroup,
  ].freeze

  def call(account, viewer: nil)
    return not_applicable(account, 'not_group') unless account.group?

    evidence = viewer_evidence_for(account, viewer)
    adapter = ADAPTERS.find { |candidate| candidate.applicable?(account) }

    return unsupported(account, 'no_supported_adapter', evidence) if adapter.nil?

    resolved(account, adapter, evidence)
  end

  private

  def viewer_evidence_for(account, viewer)
    return if account.local? || viewer.nil?

    affiliations = PostingContext::GroupAffiliationEvidenceResolver.new.call(account, viewer)
    definitions = PostingContext::GroupPermissionDefinitionResolver.new.call(account)

    # permissions joins the two cached snapshots. It does not choose an
    # adapter or change posting transport authority.
    {
      affiliations: affiliations,
      permissions: PostingContext::GroupPermissionEvidenceResolver.new.call(affiliations, definitions),
    }
  end

  def resolved(account, adapter, evidence)
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
      viewer_evidence: evidence,
    }
  end

  def unsupported(account, reason, evidence)
    neutral(account, 'unsupported', reason, evidence)
  end

  def not_applicable(account, reason)
    neutral(account, 'not_applicable', reason, nil)
  end

  def neutral(account, status, reason, evidence)
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
      viewer_evidence: evidence,
    }
  end
end
