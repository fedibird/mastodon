# frozen_string_literal: true
# == Schema Information
#
# Table name: custom_emojis
#
#  id                           :bigint(8)        not null, primary key
#  shortcode                    :string           default(""), not null
#  domain                       :string
#  image_file_name              :string
#  image_content_type           :string
#  image_file_size              :bigint(8)
#  image_updated_at             :datetime
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#  disabled                     :boolean          default(FALSE), not null
#  uri                          :string
#  image_remote_url             :string
#  visible_in_picker            :boolean          default(TRUE), not null
#  category_id                  :bigint(8)
#  image_storage_schema_version :integer
#  width                        :integer
#  height                       :integer
#  thumbhash                    :string
#  copy_permission              :integer          default("none"), not null
#  aliases                      :string           default([]), not null, is an Array
#  meta                         :jsonb            not null
#  alternate_name               :string           default(""), not null
#  ruby                         :string           default(""), not null
#  license                      :string           default(""), not null
#  usage_info                   :string           default(""), not null
#  creator                      :string           default(""), not null
#  description                  :string           default(""), not null
#  copyright_notice             :string           default(""), not null
#  credit_text                  :string           default(""), not null
#  is_based_on                  :string           default(""), not null
#  sensitive                    :boolean          default(FALSE), not null
#  related_links                :string           default([]), not null, is an Array
#  last_fetched_at              :datetime
#  reading                      :string           default(""), not null
#

class CustomEmoji < ApplicationRecord
  include Attachmentable

  LOCAL_LIMIT = (ENV['MAX_EMOJI_SIZE'] || 256.kilobytes).to_i
  LIMIT       = [LOCAL_LIMIT, (ENV['MAX_REMOTE_EMOJI_SIZE'] || 256.kilobytes).to_i].max
  MAX_PIXELS  = 750_000 # 1500x500px

  FREQUENTLY_USED_EMOJIS_LIMIT = 100

  SHORTCODE_RE_FRAGMENT = '[a-zA-Z0-9_]+'

  SCAN_RE = /(?<=[^[:alnum:]:]|\n|^)
    :(#{SHORTCODE_RE_FRAGMENT}):
    (?=[^[:alnum:]:]|$)/x

  ALIAS_KEYS = {
    'alterneteName'    => 'alternate_name',
    'aliases'          => 'keywords',
    'visibleInPicker'  => 'visible_in_picker',
    'show'             => 'visible_in_picker',
    'list'             => 'visible_in_picker',
    'misskeyLicense'   => 'misskey_license',
    '_misskey_license' => 'misskey_license',
    '_misskeyLicense'  => 'misskey_license',
    'copyrightNotice'  => 'copyright_notice',
    'creditText'       => 'credit_text',
    'usageInfo'        => 'usage_info',
    'relatedLink'      => 'related_link',
    'author'           => 'creator',
    'isBasedOn'        => 'is_based_on',
    'orgCategory'      => 'org_category',
    'copyPermission'   => 'copy_permission',
  }

  COMMON_LICENSES = {
    'http://www.apache.org/licenses/LICENSE-2.0'         => 'Apache-2.0',
    'https://creativecommons.org/licenses/by/4.0/'       => 'CC BY 4.0',
    'https://creativecommons.org/licenses/by-sa/4.0/'    => 'CC BY-SA 4.0',
    'https://creativecommons.org/licenses/by-nc/4.0/'    => 'CC BY-NC 4.0',
    'https://creativecommons.org/licenses/by-nc-sa/4.0/' => 'CC BY-NC-SA 4.0',
    'https://creativecommons.org/licenses/by-nd/4.0/'    => 'CC BY-ND 4.0',
    'https://creativecommons.org/licenses/by-nc-nd/4.0/' => 'CC BY-NC-ND 4.0',
    'https://creativecommons.org/licenses/by/3.0/'       => 'CC BY 3.0',
    'https://creativecommons.org/licenses/by-sa/3.0/'    => 'CC BY-SA 3.0',
    'https://creativecommons.org/licenses/by-nc/3.0/'    => 'CC BY-NC 3.0',
    'https://creativecommons.org/licenses/by-nc-sa/3.0/' => 'CC BY-NC-SA 3.0',
    'https://creativecommons.org/licenses/by-nd/3.0/'    => 'CC BY-ND 3.0',
    'https://creativecommons.org/licenses/by-nc-nd/3.0/' => 'CC BY-NC-ND 3.0',
    'https://creativecommons.org/publicdomain/zero/1.0/' => 'CC0',
    'https://creativecommons.org/publicdomain/mark/1.0/' => 'PD',
  }

  IMAGE_FILE_EXTENSIONS = %w(.png .gif .webp .jpg .jpeg .heif .heic .avif .bmp).freeze
  IMAGE_MIME_TYPES = %w(image/png image/gif image/webp image/jpeg image/heif image/heic image/avif image/bmp).freeze
  IMAGE_CONVERTIBLE_MIME_TYPES = %w(image/jpeg image/heif image/heic image/bmp).freeze

  GLOBAL_CONVERT_OPTIONS = {
    all: '+profile "!icc,*" +set modify-date +set create-date -define webp:use-sharp-yuv=1 -define webp:emulate-jpeg-size=true -quality 70',
    static: '-coalesce',
  }.freeze

  attr_accessor :category_name

  enum copy_permission: { none: 0, allow: 1, deny: 2, conditional: 3 }, _suffix: :permission

  belongs_to :category, class_name: 'CustomEmojiCategory', optional: true
  has_one :local_counterpart, -> { where(domain: nil) }, class_name: 'CustomEmoji', primary_key: :shortcode, foreign_key: :shortcode

  has_attached_file :image, styles: ->(f) { file_styles(f) }, processors: [:lazy_thumbnail], convert_options: GLOBAL_CONVERT_OPTIONS

  before_validation :self_domain
  before_validation :downcase_domain

  validates_attachment :image, content_type: { content_type: IMAGE_MIME_TYPES }, presence: true
  validates_attachment_size :image, less_than: LIMIT, unless: :local?
  validates_attachment_size :image, less_than: LOCAL_LIMIT, if: :local?
  validates :shortcode, uniqueness: { scope: :domain }, format: { with: /\A#{SHORTCODE_RE_FRAGMENT}\z/ }, length: { minimum: 1 }, unless: :local?
  validates :shortcode, uniqueness: { scope: :domain }, format: { with: /\A#{SHORTCODE_RE_FRAGMENT}\z/ }, length: { minimum: 2 }, if: :local?

  scope :local, -> { where(domain: nil) }
  scope :remote, -> { where.not(domain: nil) }
  scope :alphabetic, -> { order(domain: :asc, shortcode: :asc) }
  scope :reading_order, -> { order(reading: :asc) }
  scope :by_domain_and_subdomains, ->(domain) { where(domain: domain).or(where(arel_table[:domain].matches('%.' + domain))) }
  scope :listed, -> { local.where(disabled: false).where(visible_in_picker: true) }

  remotable_attachment :image, LIMIT

  before_save :set_reading
  before_save :extract_dimensions
  after_commit :remove_entity_cache

  def possibly_stale?
    return false if domain.nil?

    last_fetched_at.nil? || last_fetched_at <= 1.day.ago
  end

  def alternate_name=(val)
    self[:alternate_name] = val.presence || ''
  end

  def ruby=(val)
    self[:ruby] = val.presence || ''
  end

  def copyright_notice=(val)
    self[:copyright_notice] = val.presence || ''
  end

  def credit_text=(val)
    self[:credit_text] = val.presence || ''
  end

  def usage_info=(val)
    self[:usage_info] = val.presence || ''
  end

  def creator=(val)
    self[:creator] = val.presence || ''
  end

  def description=(val)
    self[:description] = val.presence || ''
  end

  def is_based_on=(val)
    self[:is_based_on] = val.presence || ''
  end

  def keywords
    aliases.join(' ')
  end

  def keywords=(val)
    if val.is_a?(Array)
      self[:aliases] = val.join(' ').split(/[ \u3000\r\n]/).compact_blank
    elsif val.is_a?(String)
      self[:aliases] = val.split(/[ \u3000\r\n]/).compact_blank
    else
      self[:aliases] = []
    end
  end

  def related_link
    self[:related_links].join("\n") || ''
  end

  def related_links
    self[:related_links].compact_blank
  end

  def related_link=(val)
    self.related_links=(val)
  end

  def related_links=(val)
    if val.is_a?(Array)
      self[:related_links] = val.compact_blank
    elsif val.is_a?(String)
      self[:related_links] = val.split(/[ \r\n]/).compact_blank
    else
      self[:related_links] = []
    end
  end

  def license=(val)
    self[:license] = COMMON_LICENSES.find { |_k, v| v == val }&.first || val.presence || ''
  end

  def license_name
    COMMON_LICENSES[self[:license]]
  end

  def misskey_license
    meta['misskey_license']
  end

  def misskey_license=(val)
    meta['misskey_license'] = val.presence || ''
  end

  def org_category
    meta['org_category']
  end

  def org_category=(val)
    meta['org_category'] = val.presence || ''
  end

  def local?
    domain.nil?
  end

  def remote?
    !local?
  end

  def object_type
    :emoji
  end

  def copy!(on_existance_action = :rename)
    copy = self.class.find_or_initialize_by(domain: nil, shortcode: shortcode) { |new_copy| new_copy.visible_in_picker = false }

    case on_existance_action
    when :rename
      unless copy.new_record? || copy.is_based_on != self.uri
        _, base, num = shortcode.match(/^(.*?)(\d+)?$/).to_a
        len = num&.length || 1
        num = num&.to_i || 0
        template = "#{base}%0#{len}<num>d"

        loop do
          num += 1
          shortcode = format(template, num: num)
          copy = self.class.new(domain: nil, shortcode: shortcode)
          break unless copy.nil?
        end

        copy.visible_in_picker = false
      end
    end
    copy.image = image
    copy.width = self.width
    copy.height = self.height
    copy.thumbhash = self.thumbhash
    copy.alternate_name = self.alternate_name
    copy.ruby = self.ruby
    copy.license = self.license
    copy.usage_info = self.usage_info
    copy.creator = self.creator
    copy.description = self.description
    copy.copyright_notice = self.copyright_notice
    copy.credit_text = self.credit_text
    copy.is_based_on = self.uri
    copy.sensitive = self.sensitive
    copy.copy_permission = self.copy_permission unless none_permission?
    copy.keywords = self.aliases if copy.aliases.blank?
    copy.meta.merge!(self.meta.compact_blank)
    copy.tap(&:save!)
  end

  def fetch
    if domain.nil?
      return if is_based_on.blank?

      updated_emoji = ResolveURLService.new.call(is_based_on)
      updated_emoji.copy!(:override) if updated_emoji.present?
    else
      ResolveURLService.new.call(uri) unless domain.nil?
    end
  end

  class << self
    def from_text(text, domain = nil)
      return [] if text.blank?

      shortcodes = text.scan(SCAN_RE).map(&:first).uniq

      return [] if shortcodes.empty?

      EntityCache.instance.emoji(shortcodes, domain)
    end

    def search(searchtext, type = :include)
      prefix = %i(end_with include).include?(type) ? '%' : ''
      suffix = %i(start_with include).include?(type) ? '%' : ''
      searchtext = "#{prefix}#{CustomEmoji.sanitize_sql_like(searchtext.strip)}#{suffix}"
      where("custom_emojis.id IN (select distinct id from (select id, unnest(shortcode || alternate_name || ruby || aliases || reading) as val from custom_emojis) e where val ilike :searchtext)", { searchtext: searchtext })
    end

    private

    def file_styles(file)
      styles = {
        original: {
          pixels: MAX_PIXELS,
          animated: true,
          file_geometry_parser: FastGeometryParser,
        },
    
        static: {
          format: 'webp',
          content_type: 'image/webp',
          animated: false,
          file_geometry_parser: FastGeometryParser,
        },
      }

      if IMAGE_CONVERTIBLE_MIME_TYPES.include?(file.content_type)
        styles[:original].merge!({
          format: 'webp',
          content_type: 'image/webp',
          animated: true,
        })
      end

      styles
    end
  end

  private

  def set_reading
    self.reading = ruby.presence || aliases.find { |k| k&.kana? } || shortcode.hiragana
  end

  def extract_dimensions
    file = image.queued_for_write[:original]

    return if file.nil?

    width, height = FastImage.size(file.path)

    return nil if width.nil?

    self.width  = width
    self.height = height
  end

  def remove_entity_cache
    Rails.cache.delete(EntityCache.instance.to_key(:emoji, shortcode, domain))
  end

  def self_domain
    self.domain = nil if domain == Rails.configuration.x.local_domain
  end

  def downcase_domain
    self.domain = domain.downcase unless domain.nil?
  end
end
