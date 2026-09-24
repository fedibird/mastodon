# frozen_string_literal: true
# == Schema Information
#
# Table name: preview_cards
#
#  id                           :bigint(8)        not null, primary key
#  url                          :string           default(""), not null
#  title                        :string           default(""), not null
#  description                  :string           default(""), not null
#  image_file_name              :string
#  image_content_type           :string
#  image_file_size              :bigint(8)
#  image_updated_at             :datetime
#  type                         :integer          default("link"), not null
#  html                         :text             default(""), not null
#  author_name                  :string           default(""), not null
#  author_url                   :string           default(""), not null
#  provider_name                :string           default(""), not null
#  provider_url                 :string           default(""), not null
#  width                        :integer          default(0), not null
#  height                       :integer          default(0), not null
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#  embed_url                    :string           default(""), not null
#  image_storage_schema_version :integer
#  blurhash                     :string
#  thumbhash                    :string
#  redirected_url               :string
#

class PreviewCard < ApplicationRecord
  include Attachmentable

  IMAGE_MIME_TYPES = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].freeze
  LIMIT = 2.megabytes

  BLURHASH_OPTIONS = {
    x_comp: 4,
    y_comp: 4,
  }.freeze

  GLOBAL_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -define webp:use-sharp-yuv=1 -define webp:emulate-jpeg-size=true -quality 90',
  }.freeze

  IMAGE_STYLES = {
    original: {
      format: 'webp',
      content_type: 'image/webp',
      animated: false,
      pixels: 230_400, # 640x360px
      file_geometry_parser: FastGeometryParser,
      processors: [:lazy_thumbnail],
    }.freeze,

    tiny: {
      format: 'webp',
      content_type: 'image/webp',
      pixels: 25_680, # 214x120px
      file_geometry_parser: FastGeometryParser,
      processors: [:lazy_thumbnail, :blurhash_transcoder, :thumbhash_transcoder],
      blurhash: BLURHASH_OPTIONS,
    }.freeze,
  }

  self.inheritance_column = false

  update_index('statuses') { statuses }

  enum type: [:link, :photo, :video, :rich]
  enum link_type: { unknown: 0, article: 1 }, _prefix: :link

  has_and_belongs_to_many :statuses
  has_one :trend, class_name: 'PreviewCardTrend', inverse_of: :preview_card, dependent: :destroy

  has_attached_file :image, styles: IMAGE_STYLES, convert_options: GLOBAL_CONVERT_OPTIONS
  validates :url, presence: true, uniqueness: true
  validates_attachment_content_type :image, content_type: IMAGE_MIME_TYPES
  validates_attachment_size :image, less_than: LIMIT
  remotable_attachment :image, LIMIT

  scope :cached, -> { where.not(image_file_name: [nil, '']) }

  before_save :extract_dimensions, if: :link?

  def appropriate_for_trends?
    link? && link_article? && title.present? && description.present? && image.present? && provider_name.present?
  end

  def domain
    Addressable::URI.parse(url).normalized_host
  end

  def provider
    @provider ||= PreviewCardProvider.matching_domain(domain)
  end

  attr_writer :provider

  def trendable?
    if attributes['trendable'].nil?
      provider&.trendable?
    else
      attributes['trendable']
    end
  end

  def requires_review?
    attributes['trendable'].nil? && (provider.nil? || provider.requires_review?)
  end

  def requires_review_notification?
    attributes['trendable'].nil? && (provider.nil? || provider.requires_review_notification?)
  end

  def decaying?
    max_score_at && max_score_at >= Trends.links.options[:max_score_cooldown].ago && max_score_at < 1.day.ago
  end

  def history
    @history ||= Trends::History.new('links', id)
  end

  def local?
    false
  end

  def missing_image?
    width.present? && height.present? && image_file_name.blank?
  end

  def save_with_optional_image!
    save!
  rescue ActiveRecord::RecordInvalid
    self.image = nil
    save!
  end

  private

  def extract_dimensions
    file = image.queued_for_write[:original]

    return if file.nil?

    width, height = FastImage.size(file.path)

    return nil if width.nil?

    self.width  = width
    self.height = height
  end
end
