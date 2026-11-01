# frozen_string_literal: true

class GroupProtocol::Assembler
  def initialize(account, viewer)
    @account = account
    @viewer = viewer
  end

  def call
    implementation = GroupProtocol::ImplementationReader.new(@account).call
    profile = GroupProtocol::ProfileReader.new(@account).call
    capabilities = GroupProtocol::CapabilityReader.new(@account, @viewer).call

    {
      schema_version: GroupProtocol::SCHEMA_VERSION,
      account_id: @account.id.to_s,
      group: @account.group?,
      local: @account.local?,
      implementation: implementation,
      profile: profile,
      compatibility_candidates: candidates(implementation),
      remote_fedibird: remote_fedibird(implementation),
      fedibird_posting: fedibird_posting,
      authorizes_posting: false,
      actor_capabilities: capabilities.fetch(:actor),
      viewer_capabilities: capabilities.fetch(:viewer),
    }
  end

  private

  def candidates(implementation)
    return [] unless @account.group?
    return [] unless implementation[:identity] == 'self_declared'

    name = GroupProtocol::COMPATIBILITY_CANDIDATES[implementation[:software_name]]
    name ? [name] : []
  end

  def remote_fedibird(implementation)
    return 'not_applicable' unless @account.group? && !@account.local?
    return 'self_declared' if implementation[:fedibird_named]

    'not_determined'
  end

  def fedibird_posting
    return 'not_applicable' unless @account.group?
    return 'server_local' if @account.local?

    'withheld'
  end
end
