# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Granular like, repost, and reply collections. transition:generic is
    # requested only after an explicit checkbox and only when the server
    # lists no repo scope. Granted scopes must be a subset of the request.
    class Scopes
      GRANULAR = [
        'atproto',
        'repo:app.bsky.feed.like',
        'repo:app.bsky.feed.repost',
        'repo:app.bsky.feed.post',
      ].freeze
      GENERIC = %w(atproto transition:generic).freeze
      FORBIDDEN = /\A(?:transition:chat|transition:email|blob:|account:|rpc:)/

      def self.choose(supported, consent:)
        list = Array(supported).map(&:to_s)
        raise Error, :unsupported_scopes unless list.include?('atproto')
        return GRANULAR.dup if list.any? { |scope| scope.start_with?('repo:') } || !list.include?('transition:generic')
        raise Error, :unsupported_scopes unless consent

        GENERIC.dup
      end

      def self.accept!(requested, granted)
        got = granted.to_s.split(/\s+/).reject(&:empty?)
        wanted = Array(requested)
        raise Error, :unsupported_scopes if got.empty? || !got.include?('atproto')
        raise Error, :unsupported_scopes if (got - wanted).any? || got.any? { |scope| FORBIDDEN.match?(scope) }

        [got, (wanted - got).any?]
      end
    end
  end
end
