# frozen_string_literal: true

# Rejects assessments that would collapse the P0 distinctions: a remote
# Fedibird guess, a reserved profile, an estimated capability, or a posting grant.
class GroupProtocol::Contract
  def self.assert!(assessment)
    new(assessment).assert!
  end

  def initialize(assessment)
    @assessment = assessment
  end

  def assert!
    assert_outcome
    assert_profile
    assert_implementation
    assert_actor
    assert_viewer
    assert_public_shape
  end

  private

  def assert_outcome
    remote = @assessment[:remote_fedibird]
    posting = @assessment[:fedibird_posting]
    named = @assessment.dig(:implementation, :fedibird_named)

    reject('posting grant') if @assessment[:authorizes_posting]
    reject('determined remote') if remote == GroupProtocol::FUTURE_REMOTE_FEDIBIRD_DETERMINED
    reject('remote state') unless GroupProtocol::REMOTE_FEDIBIRD_STATES.include?(remote)
    reject('posting state') unless GroupProtocol::FEDIBIRD_POSTING_STATES.include?(posting)
    reject('named remote') if named != (remote == 'self_declared')
    reject('local posting') if posting == 'server_local' && !(@assessment[:local] && @assessment[:group])
    reject('remote posting') if posting == 'withheld' && @assessment[:local]
    reject('self-declared profile') if remote == 'self_declared' && @assessment.dig(:profile, :kind) != 'unknown'
    reject('self-declared release') if remote == 'self_declared' && posting != 'withheld'
  end

  def assert_profile
    kind = @assessment.dig(:profile, :kind)
    reject('reserved profile') if GroupProtocol::RESERVED_PROFILE_KINDS.include?(kind)
    reject('profile kind') unless GroupProtocol::PROFILE_KINDS.include?(kind)
    reject('non-group profile') if !@assessment[:group] && kind != 'not_applicable'
    reject('local profile') if @assessment[:group] && @assessment[:local] && kind != 'fedibird_mention_follow_announce'
    reject('remote profile') if @assessment[:group] && !@assessment[:local] && kind != 'unknown'
    assert_evidence(@assessment.dig(:profile, :evidence))
  end

  def assert_implementation
    implementation = @assessment[:implementation]
    reject('identity') unless GroupProtocol::IMPLEMENTATION_IDENTITIES.include?(implementation[:identity])
    reject('family') unless GroupProtocol::FAMILIES.include?(implementation[:family])
    assert_evidence(implementation[:evidence])
    reject('server identity') if @assessment[:local] && implementation[:identity] != 'server'
    reject('remote server identity') if !@assessment[:local] && implementation[:identity] == 'server'
  end

  def assert_actor
    rows = @assessment[:actor_capabilities]
    unless @assessment[:group]
      reject('actor capabilities') unless rows.empty?
      return
    end

    assert_capabilities(rows, GroupProtocol::ACTOR_CAPABILITIES, 'actor')
    released = rows.find { |row| row[:name] == 'remote_posting_released' }
    reject('remote release') unless released && released[:state] == 'withheld' && released[:value] == false
  end

  def assert_viewer
    viewer = @assessment[:viewer_capabilities]
    if !@assessment[:group] || viewer.nil?
      reject('viewer capabilities') unless viewer.nil?
      return
    end

    assert_capabilities(viewer, GroupProtocol::VIEWER_CAPABILITIES, 'viewer')
    can_post = viewer.find { |row| row[:name] == 'can_post' }
    reject('can_post grant') unless can_post && can_post[:state] == 'unknown' && can_post[:value].nil?
  end

  def assert_capabilities(rows, names, scope)
    reject("#{scope} catalog") unless rows.map { |row| row[:name] } == names
    rows.each do |row|
      reject("#{scope} scope") unless row[:scope] == scope
      assert_capability_value(row)
      assert_evidence(row[:evidence])
    end
  end

  def assert_capability_value(row)
    state = row[:state]
    reject('reserved capability') if GroupProtocol::RESERVED_CAPABILITY_STATES.include?(state)
    reject('capability state') unless GroupProtocol::CAPABILITY_STATES.include?(state)
    value = row[:value]
    case state
    when 'unknown', 'unfetched'
      reject('unknown value') unless value.nil?
    when 'withheld'
      reject('withheld value') unless value == false
    when 'observed', 'denied'
      reject('empty observation') if value.nil?
    end
  end

  def assert_evidence(evidence)
    reject('evidence keys') unless evidence.is_a?(Hash) && evidence.keys == GroupProtocol::EVIDENCE_KEYS
    reject('authority') unless GroupProtocol::AUTHORITIES.include?(evidence[:authority])
    reject('freshness') unless GroupProtocol::FRESHNESS.include?(evidence[:freshness])
    reject('uncertainty') unless GroupProtocol::UNCERTAINTIES.include?(evidence[:uncertainty])
  end

  def assert_public_shape
    reject('public viewer key') if (GroupProtocol::PUBLIC_KEYS & %i(viewer_capabilities)).any?
    public_rows = @assessment[:actor_capabilities]
    reject('public viewer capability') if public_rows.any? { |row| GroupProtocol::VIEWER_CAPABILITIES.include?(row[:name]) }
  end

  def reject(reason)
    raise GroupProtocol::ContractError, reason
  end
end
