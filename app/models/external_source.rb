# frozen_string_literal: true

# == Schema Information
#
# Table name: external_sources
#
#  id                                 :bigint(8)        not null, primary key
#  protocol                           :string           not null
#  canonical_key                      :text             not null
#  etag                               :text
#  last_modified                      :text
#  fetched_at                         :datetime
#  checked_at                         :datetime
#  title                              :text
#  site_url                           :text
#  created_at                         :datetime         not null
#  updated_at                         :datetime         not null
#  icon_file_name                     :string
#  icon_content_type                  :string
#  icon_file_size                     :bigint(8)
#  icon_updated_at                    :datetime
#  icon_fingerprint                   :string
#  icon_remote_url                    :text
#  icon_origin                        :string
#  icon_etag                          :text
#  icon_last_modified                 :text
#  icon_hints                         :jsonb
#  icon_checked_at                    :datetime
#  icon_next_check_at                 :datetime
#  icon_failure_count                 :integer          default(0), not null
#  icon_error_code                    :string
#  activitypub_state                  :string           default("unknown"), not null
#  activitypub_hint                   :boolean          default(FALSE), not null
#  activitypub_generator_hint         :boolean          default(FALSE), not null
#  activitypub_feed_attribution       :string           default("unknown"), not null
#  host_activitypub_supported         :string           default("unknown"), not null
#  activitypub_instance_state         :string           default("unknown"), not null
#  activitypub_software               :string
#  activitypub_instance_checked_at    :datetime
#  activitypub_instance_next_check_at :datetime
#  activitypub_ordinary_blocked_until :datetime
#
# The icon is one stored copy shared by every subscriber of the feed. Only the
# fetch job (ExternalBridge::RSS::Icon::RefreshSource) writes it. It is served
# through ExternalSourceIconsController, never from the original URL.
class ExternalSource < ApplicationRecord
  include Attachmentable

  PROTOCOLS = %w(rss atom).freeze
  # NodeInfo self-report for the host that serves the feed. This is not
  # evidence that this RSS document is that ActivityPub implementation's feed.
  HOST_ACTIVITYPUB_UNKNOWN = 'unknown'
  HOST_ACTIVITYPUB_SUPPORTED = 'supported'
  HOST_ACTIVITYPUB_NOT_ADVERTISED = 'not_advertised'
  # activitypub_feed_attribution is a guess, not a confirmed origin.
  # "likely" means the generator names a known ActivityPub project and an
  # entry sits on the feed host. Later code must not treat it as proof.
  FEED_ATTRIBUTION_UNKNOWN = 'unknown'
  FEED_ATTRIBUTION_LIKELY = 'likely'
  # activitypub_state on a source is unknown, hinted, or items_verified.
  # It is never "verified": that word is reserved for a resource whose
  # candidate URL returned ActivityStreams.
  ICON_MIME_TYPES = %w(image/png image/jpeg image/gif image/webp image/vnd.microsoft.icon image/x-icon).freeze
  ICON_UNPROCESSED_MIME_TYPES = %w(image/vnd.microsoft.icon image/x-icon).freeze
  ICON_SIZE = 128
  ICON_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -quality 90',
  }.freeze

  # Stored as a still 128px square WebP. A GIF keeps only its first frame, and
  # the geometry never upscales a smaller source. An ICO is stored as fetched:
  # it was already checked for type, size, and dimensions, and it never goes
  # through ImageMagick's ICO coder.
  has_attached_file :icon,
                    styles: ->(attachment) { icon_styles(attachment) },
                    convert_options: ICON_CONVERT_OPTIONS

  def self.icon_styles(attachment)
    return { original: { processors: [:pass_through] } } if ICON_UNPROCESSED_MIME_TYPES.include?(attachment.content_type)

    {
      original: {
        geometry: "#{ICON_SIZE}x#{ICON_SIZE}#",
        format: 'webp',
        content_type: 'image/webp',
        animated: false,
        file_geometry_parser: FastGeometryParser,
        processors: [:lazy_thumbnail, :type_corrector],
        source_file_options: '-limit time 10 -limit area 32MP',
      },
    }
  end
  private_class_method :icon_styles

  validates_attachment_content_type :icon, content_type: ICON_MIME_TYPES
  validates_attachment_size :icon, less_than: 1.megabyte

  has_many :external_resources, dependent: :restrict_with_exception
  has_many :external_subscriptions, dependent: :restrict_with_exception

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :canonical_key, presence: true

  def host_reports_activitypub?
    host_activitypub_supported == HOST_ACTIVITYPUB_SUPPORTED
  end

  def likely_activitypub_feed?
    activitypub_feed_attribution == FEED_ATTRIBUTION_LIKELY
  end

  # Exploration is over when any of these is true. New ordinary permalinks
  # may then take a slot that a checked row has released. This is still not
  # proof that the feed is that server's ActivityPub output.
  def activitypub_fresh_items_allowed?
    host_reports_activitypub? || likely_activitypub_feed? || external_resources.where(activitypub_state: 'verified', source_deleted_at: nil).exists?
  end

  def ordinary_activitypub_probe_blocked?(now = Time.current)
    return false if activitypub_fresh_items_allowed?

    activitypub_ordinary_blocked_until.present? && activitypub_ordinary_blocked_until > now
  end
end
