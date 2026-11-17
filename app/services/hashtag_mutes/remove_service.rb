# frozen_string_literal: true

class HashtagMutes::RemoveService < BaseService
  # Drops the tag rules on this filter. Keywords and individual posts stay.
  # The filter itself goes away only when nothing else is attached to it.
  def call(filter)
    ApplicationRecord.transaction do
      filter.filter_tags.each(&:destroy!)
      filter.reload

      if filter.keywords.exists? || filter.statuses.exists? || filter.filter_tags.exists?
        filter
      else
        filter.destroy!
        nil
      end
    end
  end
end
