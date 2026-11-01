# frozen_string_literal: true

# Software identity from this server, or from the stored NodeInfo snapshot.
# A fresh self-declaration is not a Group protocol and not posting permission.
class GroupProtocol::ImplementationReader
  def initialize(account)
    @account = account
  end

  def call
    return server_implementation if @account.local?

    node = @account.node
    return unbound('unknown', 'unfetched', 'absent') if node.nil?
    return unbound('withheld', 'not_applicable', 'domain_mismatch', node) unless same_domain?(node)
    return unbound('withheld', 'missing', 'nodeinfo_missing', node) if node.missing?
    return unbound('withheld', 'unfetched', 'absent', node) if node.last_fetched_at.nil?
    return snapshot(node, 'withheld', 'stale', 'stale', false) if node.possibly_stale?

    problem = actor_problem
    return unbound('withheld', 'not_applicable', problem, node) if problem

    software = software_name(node)
    return unbound('withheld', 'fresh', 'absent', node) if software.nil?

    # The flag is only the remote Group claim. A Person on a server that
    # calls itself Fedibird keeps software_name and leaves this unset.
    snapshot(node, 'self_declared', 'fresh', uncertainty_for(node, software), software == 'fedibird' && @account.group?)
  end

  private

  def server_implementation
    result(
      identity: 'server',
      family: 'fedibird',
      names: { software_name: 'fedibird' },
      fedibird_named: false,
      evidence: evidence_for('server', 'server', 'current', 'none')
    )
  end

  def unbound(identity, freshness, uncertainty, node = nil)
    result(
      identity: identity,
      family: 'unknown',
      names: {},
      fedibird_named: false,
      evidence: evidence_for(node ? 'node.info' : 'none', 'none', freshness, uncertainty, node)
    )
  end

  def snapshot(node, identity, freshness, uncertainty, fedibird_named)
    software = software_name(node)
    authority = identity == 'self_declared' ? 'self_declared' : 'none'
    result(
      identity: identity,
      family: family_for(software),
      names: {
        software_name: software,
        software_version: plain_string(info(node)['software_version']),
        upstream_name: normalize_name(info(node)['upstream_name']),
        upstream_version: plain_string(info(node)['upstream_version']),
      },
      fedibird_named: fedibird_named,
      evidence: evidence_for('node.info', authority, freshness, uncertainty, node)
    )
  end

  def result(identity:, family:, names:, fedibird_named:, evidence:)
    {
      identity: identity,
      family: family,
      software_name: names[:software_name],
      software_version: names[:software_version],
      upstream_name: names[:upstream_name],
      upstream_version: names[:upstream_version],
      fedibird_named: fedibird_named,
      evidence: evidence,
    }
  end

  def evidence_for(source, authority, freshness, uncertainty, node = nil)
    observed_at, expires_at = timestamps(node)
    GroupProtocol::Evidence.build(
      source: source,
      authority: authority,
      freshness: freshness,
      uncertainty: uncertainty,
      observed_at: observed_at,
      expires_at: expires_at
    )
  end

  def actor_problem
    host = GroupProtocol::ActorHost.for_account(@account)
    return 'actor_unverified' if host.nil?
    return 'actor_mismatch' if host != @account.domain.to_s.downcase

    nil
  end

  def uncertainty_for(node, software)
    upstream = normalize_name(info(node)['upstream_name'])
    return 'upstream_only' if upstream == 'fedibird' && software != 'fedibird'

    override = normalize_name(stringify(node.info_override)['software_name'])
    return 'override_ignored' if override && override != software
    return 'self_report' if software == 'fedibird'

    'none'
  end

  def same_domain?(node)
    left = @account.domain.to_s.downcase
    right = node.domain.to_s.downcase
    left.present? && left == right
  end

  def software_name(node)
    normalize_name(info(node)['software_name'])
  end

  def family_for(software)
    return 'unknown' if software.nil?

    GroupProtocol::SOFTWARE_FAMILIES.fetch(software, 'other')
  end

  def timestamps(node)
    return [nil, nil] if node.nil? || node.last_fetched_at.nil?

    fetched = node.last_fetched_at
    [fetched.utc.iso8601, (fetched + 1.day).utc.iso8601]
  end

  def info(node)
    stringify(node.info)
  end

  def stringify(value)
    return {} unless value.is_a?(Hash)

    value.transform_keys(&:to_s)
  end

  def normalize_name(value)
    return unless value.is_a?(String)

    token = value.strip.downcase
    token.empty? ? nil : token
  end

  def plain_string(value)
    return unless value.is_a?(String)

    token = value.strip
    token.empty? ? nil : token
  end
end
