# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Confirms that a public candidate URL can return an ActivityStreams 2.0
      # content object. It does not import the object, expand JSON-LD, fetch
      # a remote context, or sign the GET.
      #
      # state "verified" means only that: the candidate URL returned an AS2
      # object. object_id is the document's self-declared id after a safety
      # check (length, http(s) URI, no credentials, no private literal). It is
      # stored verbatim, including fragments and ordinary query strings, and
      # is NOT fetched or compared with the candidate URL. object_id_status
      # is "self_reported" for that reason. A later feature must not treat
      # this row as proof that the id is the object's canonical IRI.
      class Probe
        # A plain object so `object_id` stays the ActivityStreams id. Struct
        # would override Ruby's own object_id.
        class Result
          attr_reader :state, :object_id, :object_type, :object_id_status

          def initialize(state:, object_id: nil, object_type: nil, object_id_status: nil)
            @state = state
            @object_id = object_id
            @object_type = object_type
            @object_id_status = object_id_status
          end
        end

        CONTEXT = 'https://www.w3.org/ns/activitystreams'
        OBJECT_TYPES = %w(Note Article Page Document Image Video Audio Event Question).freeze
        OBJECT_ID_SELF_REPORTED = 'self_reported'

        def call(url)
          response = HttpClient.get(url, profile: HttpClient::ACTIVITYPUB_PROFILE)
          return Result.new(state: 'inaccessible') if [401, 403].include?(response.code)
          return Result.new(state: 'unavailable') if response.code == 404
          return Result.new(state: 'error') unless response.code == 200
          return Result.new(state: 'unavailable') unless HttpClient::ACTIVITYPUB_PROFILE.content_types.include?(response.content_type)

          validate_body(response.body)
        rescue Error, JSON::ParserError, TypeError, ArgumentError
          Result.new(state: 'error')
        end

        private

        def validate_body(body)
          data = JSON.parse(body, max_nesting: 24)
          return Result.new(state: 'unavailable') unless data.is_a?(Hash)
          return Result.new(state: 'unavailable') unless Array(data['@context']).include?(CONTEXT)

          kind = Array(data['type']).find { |type| OBJECT_TYPES.include?(type) }
          return Result.new(state: 'unavailable') if kind.nil?

          id = ObjectId.preserve!(data['id'])
          Result.new(state: 'verified', object_id: id, object_type: kind, object_id_status: OBJECT_ID_SELF_REPORTED)
        rescue Error
          Result.new(state: 'unavailable')
        end
      end
    end
  end
end
