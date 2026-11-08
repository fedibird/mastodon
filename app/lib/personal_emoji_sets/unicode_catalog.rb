# frozen_string_literal: true

# Generated from the same pinned data as Nimble, but read only on the server.
# The personal picker receives individual registered images and search terms;
# it never downloads this catalog or re-applies a skin tone to a saved string.
class PersonalEmojiSets::UnicodeCatalog
  PATH = Rails.root.join('config', 'personal_emoji_set_unicode.json').freeze

  class << self
    def find(native)
      variant = data.fetch('variants')[native]
      return if variant.nil?

      id, filename = variant
      label, search = data.fetch('metadata').fetch(id)
      readings = data.fetch('readings')[native.delete("\uFE0E\uFE0F")] || []
      { id: id, filename: filename, label: label, search: (search + readings).uniq }
    end

    def fingerprint
      @fingerprint ||= Digest::SHA256.file(PATH).hexdigest.freeze
    end

    private

    def data
      @data ||= JSON.parse(File.read(PATH)).freeze
    end
  end
end
