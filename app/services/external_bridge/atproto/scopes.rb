# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # P2 requests only the identity scope. Repository scopes are a later
    # explicit upgrade, and only when that server lists each one. Granted
    # scopes must be a subset of the request. transition:generic is not requested.
    class Scopes
      IDENTITY = ['atproto'].freeze
      REPO = [
        'repo:app.bsky.feed.like',
        'repo:app.bsky.feed.repost',
        'repo:app.bsky.feed.post',
      ].freeze
      FORBIDDEN = /\A(?:transition:chat|transition:email|blob:|account:|rpc:|transition:generic)/

      def self.choose(supported)
        list = Array(supported).map(&:to_s)
        raise Error, :unsupported_scopes unless list.include?('atproto')

        IDENTITY.dup
      end

      # P3 may request these only after a separate confirmation, and only the
      # ones this authorization server lists. P2 does not send them.
      def self.upgrade_candidates
        REPO.dup
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
