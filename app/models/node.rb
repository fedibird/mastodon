# frozen_string_literal: true

# == Schema Information
#
# Table name: nodes
#
#  id                     :bigint(8)        not null, primary key
#  domain                 :string           not null
#  info                   :jsonb
#  info_override          :jsonb
#  nodeinfo               :jsonb
#  instance_data          :jsonb
#  icon_file_name         :string
#  icon_content_type      :string
#  icon_file_size         :bigint(8)
#  icon_updated_at        :datetime
#  icon_remote_url        :string
#  thumbnail_file_name    :string
#  thumbnail_content_type :string
#  thumbnail_file_size    :bigint(8)
#  thumbnail_updated_at   :datetime
#  thumbnail_remote_url   :string
#  blurhash               :string
#  thumbhash              :string
#  last_fetched_at        :datetime
#  status                 :integer          default("up"), not null
#  note                   :string           default(""), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
class Node < ApplicationRecord
  include DomainControlHelper
  include RoutingHelper
  include Attachmentable
  include NodeThumbnail
  include NodeIcon
  include Paginable

  enum status: { up: 0, gone: 1, reject: 2, busy: 3, not_found: 4, error: 5, no_address: 6 }, _suffix: :status

  has_many :accounts, primary_key: :domain, foreign_key: :domain, inverse_of: :node
  has_one :instance, primary_key: :domain, foreign_key: :domain, inverse_of: :node

  scope :domain, ->(domain) { where(domain: Addressable::URI.parse(domain).normalize.to_s.downcase) if domain.present? }
  scope :software, ->(name) { where("info->>'software_name' = ?", name.downcase) if name.present? }
  scope :upstream, ->(name) { where("info->>'upstream_name' = ?", name.downcase) if name.present? }
  scope :available, -> { where(status: :up).has_nodeinfo }
  scope :has_nodeinfo, -> { where("not(nodeinfo ? 'error' and nodeinfo->>'error' = 'missing')") }
  scope :missing, -> { where("nodeinfo is null or nodeinfo->>'error' = 'missing'") }

  ERROR_MISSING = { 'error': 'missing' }

  MASTODON_API_COMPATIBLE = %w(
    mastodon
    pleroma
    pixelfed
    gotosocial
    friendica
  )

  MISSKEY_API_COMPATIBLE = %w(
    misskey
    dolphin
  )

  FORKS = {
    'mastodon' => %w(
      hometown
      fedibird
      koyuspace
      ecko
      brighteon
      kmyblue
      yoiyami
      glitchcafe
    ),
    'misskey' => %w(
      meisskey
      areionskey
      calckey
      foundkey
      groundpolis
      groundpolis-milkey
      firefish
      sharkey
      iceshrimp
      cherrypick
      catodon
      incestoma
      nexkey
      rosekey
      hajkey
      rumisskey
      noyaskey
      goblin
      magnetar
      lycheebridge
      fishkey
    ),
    'pleroma' => %w(
      akkoma
      incestoma
      pleroma_anni
    ),
  }

  COMPATIBLES = FORKS.keys.each_with_object({}) { |upstream, h| h.merge!(FORKS[upstream].each_with_object({}) { |fork, h| h[fork]=upstream }) }

  FEATURES = {
    resolve_account: true,
    emoji_reaction_type: 'custom',
    emoji_reaction_max: [EmojiReactionValidator::MAX_PER_ACCOUNT, Setting.reaction_max_per_account].max,
    reference: true,
    favourite: true,
    reply: true,
    reblog: true,
  }

  {
    software_name: '',
    software_version: '',
    upstream_name: '',
    upstream_version: '',
    description: '',
    languages: [],
    region: '',
    categories: [],
    total_users: 0,
    last_week_users: 0,
    registrations: false,
    approval_required: nil,
    name: '',
    url: '',
    theme_color: nil,
  }.each do |key, default|
    define_method(key) do
      self[:info]&.dig(key.to_s) || default
    end
  end

  alias software software_name
  alias version software_version
  alias upstream upstream_name

  def proxied_thumbnail
    full_asset_url(thumbnail_original_url) if thumbnail_original_url.present?
  end

  def proxied_icon
    full_asset_url(icon_original_url) if icon_original_url.present?
  end

  def node?
    !missing?
  end

  def missing?
    nodeinfo.nil? || nodeinfo['error'] == 'missing'
  end

  def available?
    up_status? && !domain_not_allowed?(domain) && DeliveryFailureTracker.available?(domain)
  end

  def possibly_stale?
    last_fetched_at.nil? || last_fetched_at <= 1.day.ago
  end

  def mastodon_api_compatible?
    MASTODON_API_COMPATIBLE.include?(upstream_name&.downcase)
  end

  def misskey_api_compatible?
    MISSKEY_API_COMPATIBLE.include?(upstream_name&.downcase)
  end

  def features(feature)
    return unless FEATURES.keys.include?(feature.to_sym)

    info&.dig(feature.to_s).then { |value| value.nil? ? FEATURES[feature.to_sym] : value }
  end

  class << self
    def find_domain(domain)
      self.find_by(domain: Addressable::URI.parse(domain).normalize.to_s)
    end

    def resolve_domain(domain, **options)
      domain = Addressable::URI.parse(domain).normalize.to_s
      UpdateNodeService.new.call(domain, **options)
      find_domain(domain)
    rescue
      nil
    end

    def upstreams(fork)
      COMPATIBLES[fork&.downcase]
    end
  
    def forks(upstream)
      FORKS[upstream&.downcase]
    end
  end
end
