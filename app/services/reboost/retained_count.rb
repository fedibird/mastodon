# frozen_string_literal: true

module Reboost
  # A reported wrapper stays in the database, so its reblogs_count change is
  # stored on that wrapper. Destroy reads the row before the status is gone
  # and skips the callback decrement. Redis is not the record of the release.
  module RetainedCount
    module_function

    def release!(original, wrapper)
      return false if original.nil? || wrapper.nil?
      return false if released?(wrapper.id)

      ReboostCountRelease.transaction do
        ReboostCountRelease.create!(status_id: wrapper.id)
        original.association(:status_stat).reset
        original.decrement_count!(:reblogs_count)
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def released?(status_id)
      return false if status_id.nil?

      ReboostCountRelease.exists?(status_id: status_id)
    end
  end
end
