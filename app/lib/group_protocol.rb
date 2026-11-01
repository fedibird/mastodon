# frozen_string_literal: true

# Read-only classification of a Group actor's implementation, protocol
# profile, and capabilities. P0 does not fetch, does not advertise a new
# actor property, and does not authorize posting. PostingContext remains
# the composer gate. See docs/group_protocol_profile.md.
module GroupProtocol
  SCHEMA_VERSION = 1

  PUBLIC_KEYS = %i(
    schema_version
    account_id
    group
    local
    implementation
    profile
    compatibility_candidates
    remote_fedibird
    fedibird_posting
    authorizes_posting
    actor_capabilities
  ).freeze

  SOFTWARE_FAMILIES = {
    'fedibird' => 'fedibird',
    'mastodon' => 'mastodon',
    'mitra' => 'mitra',
    'nodebb' => 'nodebb',
    'lemmy' => 'lemmy',
    'piefed' => 'piefed',
  }.freeze

  # NodeInfo software tokens that PostingContext may already treat as
  # compatibility adapters. Here they are candidates only, never a profile.
  COMPATIBILITY_CANDIDATES = {
    'fedibird' => 'fedibird_nodeinfo',
    'mitra' => 'mitra_nodeinfo',
    'nodebb' => 'nodebb_nodeinfo',
    'lemmy' => 'lemmy_nodeinfo',
    'piefed' => 'piefed_nodeinfo',
  }.freeze

  IMPLEMENTATION_IDENTITIES = %w(server self_declared withheld unknown).freeze
  FAMILIES = (SOFTWARE_FAMILIES.values + %w(other unknown)).freeze
  PROFILE_KINDS = %w(fedibird_mention_follow_announce unknown not_applicable).freeze
  # Named so a later phase has to opt in. P0 must not emit them.
  RESERVED_PROFILE_KINDS = %w(fep_1b12_audience fep_400e).freeze
  REMOTE_FEDIBIRD_STATES = %w(not_applicable self_declared not_determined).freeze
  # Positive remote determination needs an explicit protocol feature
  # reviewed after P0. NodeInfo is not that feature.
  FUTURE_REMOTE_FEDIBIRD_DETERMINED = 'determined'
  FEDIBIRD_POSTING_STATES = %w(not_applicable server_local withheld).freeze
  AUTHORITIES = %w(server self_declared protocol none).freeze
  FRESHNESS = %w(current fresh stale missing unfetched not_applicable).freeze
  UNCERTAINTIES = %w(
    none
    self_report
    stale
    nodeinfo_missing
    actor_mismatch
    actor_unverified
    domain_mismatch
    upstream_only
    override_ignored
    absent
    not_advertised
    not_a_grant
    not_a_role
  ).freeze
  # `estimated` is reserved. A software-name heuristic must not be stored
  # as a guessed capability. It stays a compatibility candidate instead.
  CAPABILITY_STATES = %w(observed denied unknown unfetched withheld).freeze
  RESERVED_CAPABILITY_STATES = %w(estimated).freeze
  ACTOR_CAPABILITIES = %w(
    can_follow
    follow_as_membership
    requires_group_mention
    allowed_visibilities
    group_announce_delivery
    roles_independent_of_follow
    fep_1b12_audience
    fep_400e_append
    remote_posting_released
  ).freeze
  VIEWER_CAPABILITIES = %w(
    membership_follow
    role
    fep_5219_can_create
    fep_5219_can_view
    can_post
  ).freeze
  EVIDENCE_KEYS = %i(source authority freshness observed_at expires_at uncertainty).freeze

  class << self
    def assess(account, viewer: nil)
      assessment = Assembler.new(account, viewer).call
      Contract.assert!(assessment)
      assessment
    end

    # Directory-safe view. There is no viewer argument: affiliation,
    # follow, and role results are not part of this hash.
    def public_metadata(account)
      assess(account).slice(*PUBLIC_KEYS)
    end

    # Reserved until a later phase reviews an explicit protocol IRI.
    # P0 has no column, does not fetch, and ProfileReader does not call this.
    def explicit_protocol_feature(_account)
      nil
    end
  end
end
