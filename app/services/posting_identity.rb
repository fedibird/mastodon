# frozen_string_literal: true

# Sender of a post. This is not the OmniAuth Identity record, not a
# PostingContext destination, and not a UserPostingContext style.
#
# M1 derives the only usable sender from the signed-in user. Delegated
# accounts and external providers are named so later stages can extend
# the same id space, but this stage never issues them.
module PostingIdentity
  LOCAL_KIND = 'local'
  LOCAL_PROVIDER = 'fedibird'
  KNOWN_KINDS = %w(local delegated mastodon misskey bluesky).freeze
  ENABLED_KINDS = [LOCAL_KIND].freeze
  AUTHORIZATION_READY = 'ready'
  AUTHORIZATION_UNAVAILABLE = 'unavailable'
  CAPABILITY_SUPPORTED = 'supported'
  CAPABILITY_UNAVAILABLE = 'unavailable'
  CAPABILITIES = %w(post media reply group schedule).freeze

  def self.local_id(account)
    "local:#{account.id}"
  end
end
