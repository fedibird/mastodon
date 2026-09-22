# frozen_string_literal: true

class ProcessHashtagsService < BaseService
  # Creation appends tags and may set a time-limit expiry from the text.
  # Edit passes replace: true, which swaps the tag set and featured-tag
  # counters without creating, changing, or clearing that expiry.
  def call(status, tags = [], replace: false)
    if replace
      replace_tags!(status)
    else
      append_tags!(status, tags)
    end
  end

  private

  def append_tags!(status, tags)
    tags    = Extractor.extract_hashtags(status.text) if status.local?
    records = []

    Tag.find_or_create_by_names(tags) do |tag|
      status.tags << tag
      records << tag
      tag.use!(status.account, status: status, at_time: status.created_at) if status.public_visibility? && !tag.name.match(TimeLimit::TIME_LIMIT_RE)
    end

    if status.local?
      time_limit = TimeLimit.from_status(status)
      if time_limit.present?
        status.update(expires_at: time_limit.to_datetime, expires_action: :mark)
      end
    end

    return unless status.distributable?

    status.account.featured_tags.where(tag_id: records.map(&:id)).find_each do |featured_tag|
      featured_tag.increment(status.created_at)
    end
  end

  def replace_tags!(status)
    names     = status.local? ? Extractor.extract_hashtags(status.text) : []
    previous  = status.tags.to_a
    current   = Tag.find_or_create_by_names(names)
    added     = current - previous
    removed   = previous - current

    status.tags = current

    added.each do |tag|
      tag.use!(status.account, status: status, at_time: status.created_at) if status.public_visibility? && !tag.name.match(TimeLimit::TIME_LIMIT_RE)
    end

    return unless status.distributable?

    status.account.featured_tags.where(tag_id: added.map(&:id)).find_each do |featured_tag|
      featured_tag.increment(status.created_at)
    end

    status.account.featured_tags.where(tag_id: removed.map(&:id)).find_each do |featured_tag|
      featured_tag.decrement(status.id)
    end
  end
end
