# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Whether the server HOSTING the feed advertises ActivityPub via NodeInfo.
      # "advertised" is a self-report about that host. It does not mean this
      # RSS document is produced by that ActivityPub implementation, and it
      # says nothing about an individual item.
      class NodeInfoProbe
        Result = Struct.new(:state, :software, keyword_init: true)
        SCHEMAS = %w(2.1 2.0).freeze
        REL_BASE = 'http://nodeinfo.diaspora.software/ns/schema/'

        def call(feed_url)
          origin = origin_for(feed_url)
          discovery = public_json("#{origin}/.well-known/nodeinfo", origin)
          return discovery unless discovery.is_a?(Hash)

          links = Array(discovery['links']).select { |entry| entry.is_a?(Hash) }
          selected = SCHEMAS.map { |version| links.find { |entry| entry['rel'] == "#{REL_BASE}#{version}" } }.compact.first
          return Result.new(state: 'unavailable') if selected.nil?

          target = CanonicalURL.normalize!(selected['href'])
          return Result.new(state: 'error') unless HttpClient.same_origin?(target, origin)

          document = public_json(target, origin)
          return document unless document.is_a?(Hash)

          protocols = Array(document['protocols'])
          return Result.new(state: 'not_advertised') unless protocols.include?('activitypub')

          Result.new(state: 'advertised', software: software_name(document))
        rescue Error, Addressable::URI::InvalidURIError, JSON::ParserError, TypeError
          Result.new(state: 'error')
        end

        private

        def origin_for(url)
          uri = Addressable::URI.parse(CanonicalURL.normalize!(url))
          "#{uri.scheme}://#{uri.authority}"
        end

        def software_name(document)
          return nil unless document['software'].is_a?(Hash)

          name = document.dig('software', 'name').to_s.downcase
          name if name.match?(/\A[a-z0-9-]{1,64}\z/)
        end

        def public_json(url, origin)
          response = HttpClient.get(url, profile: HttpClient::NODEINFO_PROFILE, origin: origin)
          return Result.new(state: 'inaccessible') if [401, 403].include?(response.code)
          return Result.new(state: 'unavailable') if response.code == 404
          return Result.new(state: 'error') unless response.code == 200
          return Result.new(state: 'error') unless HttpClient.same_origin?(response.final_url, origin)
          return Result.new(state: 'unavailable') unless HttpClient::NODEINFO_PROFILE.content_types.include?(response.content_type)

          data = JSON.parse(response.body, max_nesting: 20)
          data.is_a?(Hash) ? data : Result.new(state: 'unavailable')
        end
      end
    end
  end
end
