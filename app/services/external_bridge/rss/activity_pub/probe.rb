# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # This verifies that a PUBLIC item URL can return an ActivityStreams 2.0
      # object. It never imports the object into the local ActivityPub pipeline.
      # No JSON-LD expansion, remote context requests, or signed GET is used.
      class Probe
        Result = Struct.new(:state, :object_id, :object_type, keyword_init: true)
        CONTEXT = 'https://www.w3.org/ns/activitystreams'
        OBJECT_TYPES = %w(Note Article Page Document Image Video Audio Event Question).freeze

        def call(url)
          response = HttpClient.get(url, profile: HttpClient::ACTIVITYPUB_PROFILE)
          return Result.new(state: 'inaccessible') if [401, 403].include?(response.code)
          return Result.new(state: 'unavailable') if response.code == 404
          return Result.new(state: 'error') unless response.code == 200
          return Result.new(state: 'unavailable') unless HttpClient::ACTIVITYPUB_PROFILE.content_types.include?(response.content_type)

          validate_body(response.body)
        rescue Error, JSON::ParserError, JSON::NestingError, TypeError, ArgumentError
          Result.new(state: 'error')
        end

        private

        def validate_body(body)
          data = JSON.parse(body, max_nesting: 24)
          return Result.new(state: 'unavailable') unless data.is_a?(Hash)
          return Result.new(state: 'unavailable') unless Array(data['@context']).include?(CONTEXT)

          kind = Array(data['type']).find { |type| OBJECT_TYPES.include?(type) }
          return Result.new(state: 'unavailable') if kind.nil?

          id = CanonicalURL.normalize!(data['id'], item: true)
          if Addressable::URI.parse(id).query.to_s.split('&').any? { |pair| pair.start_with?('viewkey=') }
            return Result.new(state: 'unavailable')
          end
          Result.new(state: 'verified', object_id: id, object_type: kind)
        rescue Error
          Result.new(state: 'unavailable')
        end
      end
    end
  end
end
