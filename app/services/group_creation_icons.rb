# frozen_string_literal: true

# Private original bytes for a group creation request.
#
# These files are not an Account avatar and not a Paperclip attachment.
# Paperclip's defaults publish to public/system, public-read S3, or a public
# Swift container. See docs/group_management_p1.md.
module GroupCreationIcons
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class NotFound < Error; end

  KEY_FORMAT = /\A[0-9a-f]{64}\z/
  MAX_BYTES = AccountAvatar::LIMIT
  MAX_PIXELS = 8_294_400 # 3840x2160, same ceiling as media images
  MAX_DIMENSION = 8_192
  DRAFT_TTL = 30.minutes
  SWEEP_GRACE = 24.hours

  MIME_EQUIVALENTS = {
    'image/jpeg' => %w(image/jpeg image/pjpeg).freeze,
    'image/png' => %w(image/png image/apng).freeze,
    'image/gif' => %w(image/gif).freeze,
    'image/webp' => %w(image/webp).freeze,
    'image/bmp' => %w(image/bmp image/x-bmp image/x-ms-bmp).freeze,
    'image/vnd.microsoft.icon' => %w(image/vnd.microsoft.icon image/x-icon image/vnd.microsoft.icon).freeze,
  }.freeze

  FAST_IMAGE_TYPES = {
    jpeg: 'image/jpeg',
    png: 'image/png',
    gif: 'image/gif',
    webp: 'image/webp',
    bmp: 'image/bmp',
    ico: 'image/vnd.microsoft.icon',
  }.freeze

  def self.generate_key
    SecureRandom.hex(32)
  end

  def self.relative_path(key)
    raise Error, 'invalid icon key' unless key.is_a?(String) && KEY_FORMAT.match?(key)

    "group-creation-icons/#{key[0, 2]}/#{key[2, 2]}/#{key}"
  end
end
