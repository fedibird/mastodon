# frozen_string_literal: true

# Actor-scoped facts and, when a viewer is supplied, that viewer's
# separate permission facts. Unknown stays nil. It is not stored as false.
class GroupProtocol::CapabilityReader
  def initialize(account, viewer)
    @account = account
    @viewer = viewer
  end

  def call
    return { actor: [], viewer: nil } unless @account.group?

    {
      actor: @account.local? ? local_actor_capabilities : remote_actor_capabilities,
      viewer: @viewer ? viewer_capabilities : nil,
    }
  end

  private

  def local_actor_capabilities
    evidence = server_evidence
    [
      cap('can_follow', 'observed', true, evidence),
      cap('follow_as_membership', 'observed', true, evidence),
      cap('requires_group_mention', 'observed', true, evidence),
      cap('allowed_visibilities', 'observed', %w(public unlisted), evidence),
      cap('group_announce_delivery', 'observed', 'announce_original_uri', evidence),
      cap('roles_independent_of_follow', 'observed', true, evidence),
      cap('fep_1b12_audience', 'denied', false, evidence),
      cap('fep_400e_append', 'denied', false, evidence),
      remote_posting_released,
    ]
  end

  def remote_actor_capabilities
    evidence = unknown_evidence
    [
      cap('can_follow', 'unknown', nil, evidence),
      cap('follow_as_membership', 'unknown', nil, evidence),
      cap('requires_group_mention', 'unknown', nil, evidence),
      cap('allowed_visibilities', 'unknown', nil, evidence),
      cap('group_announce_delivery', 'unknown', nil, evidence),
      cap('roles_independent_of_follow', 'unknown', nil, evidence),
      cap('fep_1b12_audience', 'unknown', nil, evidence),
      cap('fep_400e_append', 'unknown', nil, evidence),
      remote_posting_released,
    ]
  end

  def viewer_capabilities
    [
      membership_capability,
      role_capability,
      *fep_capabilities,
      can_post_capability,
    ]
  end

  def membership_capability
    unless @account.local?
      return cap('membership_follow', 'unknown', nil, unknown_evidence, 'viewer')
    end

    if @viewer.following?(@account)
      cap('membership_follow', 'observed', true, follow_evidence, 'viewer')
    else
      cap('membership_follow', 'denied', false, follow_evidence, 'viewer')
    end
  end

  def role_capability
    unless @account.local?
      return cap('role', 'unknown', nil, role_unknown_evidence, 'viewer')
    end

    assignment = GroupRoleAssignment.active.find_by(group_account_id: @account.id, member_account_id: @viewer.id)
    if assignment
      cap('role', 'observed', assignment.role, role_evidence, 'viewer')
    else
      cap('role', 'denied', 'none', role_evidence, 'viewer')
    end
  end

  def fep_capabilities
    affiliations = PostingContext::GroupAffiliationEvidenceResolver.new.call(@account, @viewer)
    definitions = PostingContext::GroupPermissionDefinitionResolver.new.call(@account)
    permissions = PostingContext::GroupPermissionEvidenceResolver.new.call(affiliations, definitions)

    [
      fep_capability('fep_5219_can_create', permissions[:create], affiliations, definitions),
      fep_capability('fep_5219_can_view', permissions[:view], affiliations, definitions),
    ]
  end

  # `allowed` is a fresh observation only. The permission resolver returns it
  # when the definition snapshot is fresh, and, unless the identifier is
  # none, when the affiliation snapshot is fresh too. A stale or unfetched
  # allow must not be stored as fresh evidence.
  def fep_capability(name, decision, affiliations, definitions)
    if decision[:status] == 'allowed'
      reject_stale_allow!(decision, affiliations, definitions)
      return cap(name, 'observed', true, fep_evidence('fresh', 'none'), 'viewer')
    end

    freshness, state, uncertainty = fep_unknown(affiliations[:snapshot_status], definitions[:snapshot_status])
    cap(name, state, nil, fep_evidence(freshness, uncertainty), 'viewer')
  end

  def reject_stale_allow!(decision, affiliations, definitions)
    return if definitions[:snapshot_status] == 'fresh' && affiliation_supports_allow?(decision, affiliations)

    raise GroupProtocol::ContractError, 'stale fep allow'
  end

  def affiliation_supports_allow?(decision, affiliations)
    return true if decision[:via_relationship] == PostingContext::GroupPermissionEvidenceResolver::NO_AFFILIATION

    affiliations[:snapshot_status] == 'fresh'
  end

  def fep_unknown(affiliation_status, definition_status)
    if affiliation_status == 'stale' || definition_status == 'stale'
      %w(stale unknown stale)
    elsif affiliation_status == 'unfetched' || definition_status == 'unfetched'
      %w(unfetched unfetched absent)
    elsif affiliation_status == 'fresh' && definition_status == 'fresh'
      %w(fresh unknown none)
    else
      %w(missing unknown absent)
    end
  end

  def can_post_capability
    cap(
      'can_post',
      'unknown',
      nil,
      GroupProtocol::Evidence.build(
        source: 'group_protocol.p0',
        authority: 'none',
        freshness: 'not_applicable',
        uncertainty: 'not_a_grant'
      ),
      'viewer'
    )
  end

  def remote_posting_released
    cap(
      'remote_posting_released',
      'withheld',
      false,
      GroupProtocol::Evidence.build(
        source: 'group_protocol.p0',
        authority: 'none',
        freshness: 'current',
        uncertainty: 'none'
      )
    )
  end

  def cap(name, state, value, evidence, scope = 'actor')
    stored = value.is_a?(Array) ? value.dup : value
    {
      name: name,
      scope: scope,
      state: state,
      value: stored,
      evidence: evidence.dup,
    }
  end

  def server_evidence
    GroupProtocol::Evidence.build(
      source: 'builtin:fedibird-group',
      authority: 'server',
      freshness: 'current',
      uncertainty: 'none'
    )
  end

  def unknown_evidence
    GroupProtocol::Evidence.build(
      source: 'none',
      authority: 'none',
      freshness: 'not_applicable',
      uncertainty: 'not_advertised'
    )
  end

  def follow_evidence
    GroupProtocol::Evidence.build(
      source: 'local_follow',
      authority: 'server',
      freshness: 'current',
      uncertainty: 'none'
    )
  end

  def role_evidence
    GroupProtocol::Evidence.build(
      source: 'group_role_assignments',
      authority: 'server',
      freshness: 'current',
      uncertainty: 'none'
    )
  end

  def role_unknown_evidence
    GroupProtocol::Evidence.build(
      source: 'none',
      authority: 'none',
      freshness: 'not_applicable',
      uncertainty: 'not_a_role'
    )
  end

  def fep_evidence(freshness, uncertainty)
    GroupProtocol::Evidence.build(
      source: PostingContext::GroupPermissionEvidenceResolver::SOURCE,
      authority: 'protocol',
      freshness: freshness,
      uncertainty: uncertainty
    )
  end
end
