# frozen_string_literal: true

module AccountTagPage
  # Public page for one author's posts with one hashtag.
  # A software name is not proof that the route still exists. Unknown
  # software, an unreadable version, or a profile host that is not the Node
  # host yields nil.
  class Resolver
    include RoutingHelper

    MASTODON_VERSION = /\A(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.\-]+|[A-Za-z][0-9A-Za-z.\-]*)?\z/
    USERNAME = /\A[A-Za-z0-9_]{1,30}\z/
    HOST = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/

    def self.call(account:, tag:, software_name: nil, software_version: nil)
      new(account, tag, software_name, software_version).call
    end

    def initialize(account, tag, software_name, software_version)
      @account = account
      @tag = tag
      @software_name = software_name
      @software_version = software_version
    end

    def call
      return if @account.nil?

      name = tag_name
      username = @account.username.to_s
      return unless USERNAME.match?(username)
      return unless usable_tag?(name)

      return local_url(username, name) if @account.local?

      remote_url(username, name)
    rescue Addressable::URI::InvalidURIError, ArgumentError
      nil
    end

    private

    def tag_name
      value = @tag.respond_to?(:name) ? @tag.name : @tag
      value.to_s
    end

    def usable_tag?(name)
      name.length.between?(1, 255) && name.match?(Tag::HASHTAG_NAME_RE) && !name.include?('%')
    end

    def local_url(username, name)
      url = short_account_tag_url(username, name)
      parsed = Addressable::URI.parse(url)
      return unless %w(https http).include?(parsed.scheme)
      return if parsed.query.present? || parsed.fragment.present?

      url
    end

    def remote_url(username, name)
      return unless supported_remote?
      return unless (host = profile_host)

      path = "/@#{encode_segment(username)}/tagged/#{encode_segment(name)}"
      return if path.include?('//') || path.match?(/[\\?#\s]/)

      uri = Addressable::URI.new(scheme: 'https', host: host, path: path)
      return unless uri.scheme == 'https' && uri.normalized_host == host
      return if uri.query.present? || uri.fragment.present? || uri.path != path

      uri.to_s
    end

    def supported_remote?
      case @software_name.to_s.strip.downcase
      when 'mastodon'
        mastodon_version?(@software_version)
      when 'fedibird'
        @software_version.to_s.strip == '0.1'
      else
        false
      end
    end

    # Mastodon gained GET /@:username/tagged/:tag in v2.8.0rc1. v2.7.4 does not
    # have it. Fedibird's own NodeInfo version is the literal "0.1".
    def mastodon_version?(version)
      match = MASTODON_VERSION.match(version.to_s.strip)
      return false unless match

      major = match[1].to_i
      minor = match[2].to_i
      return true if major > 2
      return false if major < 2
      return true if minor > 8
      return false if minor < 8

      true
    end

    def profile_host
      profile = Addressable::URI.parse(@account.url.to_s)
      return unless profile.scheme == 'https'
      return if profile.user.present? || profile.password.present? || profile.port

      host = profile.normalized_host.to_s.downcase
      node_host = normalized_domain(@account.domain)
      return unless host.present? && node_host.present? && host == node_host
      return unless HOST.match?(host)

      host
    end

    def normalized_domain(domain)
      Addressable::IDNA.to_ascii(domain.to_s).downcase
    rescue ArgumentError
      nil
    end

    def encode_segment(value)
      Addressable::URI.encode_component(value, Addressable::URI::CharacterClasses::UNRESERVED)
    end
  end
end
