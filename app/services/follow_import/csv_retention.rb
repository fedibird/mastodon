# frozen_string_literal: true

# Whether the raw Follow Import CSV must stay available.
#
# Stopped batches never execute, so their CSV may be deleted even while
# target rows remain. Screening, review_required, and an approved batch
# whose resume handoff is not yet marked complete must keep the CSV,
# including overwrite imports that still need it to compute removals.
module FollowImport
  module CsvRetention
    module_function

    def retain?(batch)
      return true if batch.screening_preflight_state?
      return true if batch.review_required_preflight_state?
      return true if batch.review_resume_pending?
      return false if batch.stopped_preflight_state?

      batch.targets.where(state: :pending).exists?
    end
  end
end
