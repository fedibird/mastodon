# frozen_string_literal: true

# Local Group Actor self-description only. This does not authorize a viewer
# to post and does not change outgoing ActivityPub delivery.
module ActivityPub
  module GroupProtocolAdvertisement
    EMIT_ENV = 'FEDIBIRD_AP_GROUP_PROTOCOLS_EMIT'
    ACTOR_IDS_ENV = 'FEDIBIRD_AP_GROUP_PROTOCOL_ACTOR_IDS'

    # HTTPS and the /v1 path are intentionally separate from Fedibird's
    # established http://fedibird.com/ns# vocabulary. These IRIs must be
    # published and independently validated before operators enable the gate.
    PROPERTY_IRI = 'https://fedibird.com/ns/group/v1#protocols'
    MENTION_FOLLOW_ANNOUNCE_IRI = 'https://fedibird.com/ns/group/v1#MentionFollowAnnounce'
    PROFILE_KIND = 'fedibird_mention_follow_announce'

    module_function

    def enabled?
      ENV[EMIT_ENV] == 'true'
    end

    # Fail closed. Setting the flag without an explicit list of local Group
    # IDs does not advertise the protocol on any Actor.
    def advertised?(account)
      return false unless enabled?
      return false if account.nil?
      return false unless account.local? && account.group? && !account.suspended? && !account.instance_actor?
      return false unless allowed_actor_ids.include?(account.id.to_i)

      server_profile?(GroupProtocol::ProfileReader.new(account).call)
    end

    def protocol_iris
      [MENTION_FOLLOW_ANNOUNCE_IRI]
    end

    # The default OFF key remains unchanged. The ON variant cannot be read
    # when the flag is disabled or this Actor is removed from the allowlist.
    def cache_key_for(account)
      return unless advertised?(account)

      "accounts/show:#{account.cache_key}:fedibird-group-protocols-v1"
    end

    def server_profile?(profile)
      profile[:kind] == PROFILE_KIND &&
        profile[:delivery] == 'announce_original_uri' &&
        profile[:requires_mention] == true &&
        profile[:requires_follow] == true &&
        profile[:allowed_visibilities] == %w(public unlisted) &&
        profile.dig(:evidence, :authority) == 'server'
    end

    def allowed_actor_ids
      ENV[ACTOR_IDS_ENV].to_s.split(/[,\s]+/).filter_map do |raw|
        Integer(raw, 10) if raw.match?(/\A[1-9]\d*\z/)
      end
    end
  end
end
