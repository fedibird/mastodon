# frozen_string_literal: true

class PersonalEmojiSets::Document
  attr_reader :revision, :picker_emoji_size, :categories

  def self.read(user)
    # Read both records under the same lock used by Save. A GET must not pair
    # one set revision with the display size from a different committed save.
    User.transaction do
      locked = User.lock.find(user.id)
      record = PersonalEmojiSet.find_by(user_id: locked.id)
      new(
        revision: record&.revision || 0,
        categories: record&.categories || [],
        picker_emoji_size: PersonalEmojiSets::PickerSize.current(locked.id)
      )
    end
  end

  def initialize(revision:, categories:, picker_emoji_size:)
    @revision = revision
    @categories = categories.deep_dup
    @picker_emoji_size = picker_emoji_size
  end

  def as_json
    stock_document.merge(categories: categories, resolved_items: resolver.resolved_items)
  end

  def stock_document
    { revision: revision, picker_emoji_size: picker_emoji_size, stock: resolver.as_json }
  end

  def etag(user_id)
    Digest::SHA256.hexdigest([user_id, stock_document, resolver.fingerprint].to_json)
  end

  private

  def resolver
    @resolver ||= PersonalEmojiSets::Stock.new(categories)
  end
end
