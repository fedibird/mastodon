# frozen_string_literal: true

# Which delivery contract is actually established for this Group.
# Local Fedibird is server authority. A remote software name is not.
class GroupProtocol::ProfileReader
  def initialize(account)
    @account = account
  end

  def call
    return inapplicable unless @account.group?
    return local_profile if @account.local?

    # Remote advertisement is not accepted in P0, including a value a
    # later stub might return. Selecting it here would skip the review
    # that has to decide Fedibird's own namespace versus a FEP IRI.
    GroupProtocol.explicit_protocol_feature(@account)
    unknown_profile
  end

  private

  def local_profile
    {
      kind: 'fedibird_mention_follow_announce',
      delivery: 'announce_original_uri',
      requires_mention: true,
      requires_follow: true,
      allowed_visibilities: %w(public unlisted),
      evidence: GroupProtocol::Evidence.build(
        source: 'builtin:fedibird-group',
        authority: 'server',
        freshness: 'current',
        uncertainty: 'none'
      ),
    }
  end

  def unknown_profile
    blank('unknown', 'not_advertised')
  end

  def inapplicable
    blank('not_applicable', 'none')
  end

  def blank(kind, uncertainty)
    {
      kind: kind,
      delivery: nil,
      requires_mention: nil,
      requires_follow: nil,
      allowed_visibilities: nil,
      evidence: GroupProtocol::Evidence.build(
        source: 'none',
        authority: 'none',
        freshness: 'not_applicable',
        uncertainty: uncertainty
      ),
    }
  end
end
