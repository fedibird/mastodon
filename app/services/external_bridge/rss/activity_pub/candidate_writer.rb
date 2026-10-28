# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # Applies a sample decision to a resource. A changed candidate is not
      # written here: the caller commits it with CandidateCommit while the
      # row lock is still held, so object evidence cannot survive the new URL.
      class CandidateWriter
        def initialize(budget)
          @budget = budget
        end

        def apply!(resource, item)
          decision = @budget.decide(item.key, resource, item)
          if resource.new_record?
            assign_new!(resource, decision)
          elsif url_changed?(resource, decision)
            stage_reset!(resource, decision)
          else
            resource.activitypub_explicit = decision.explicit
            resource.activitypub_candidate_digest = CandidateCommit.digest(decision.url)
          end
        end

        private

        def assign_new!(resource, decision)
          resource.activitypub_candidate_url = decision.url
          resource.activitypub_candidate_digest = CandidateCommit.digest(decision.url)
          resource.activitypub_explicit = decision.explicit
          resource.activitypub_state = 'unknown'
          resource.activitypub_object_id = nil
          resource.activitypub_object_id_status = nil
          resource.activitypub_object_type = nil
          resource.activitypub_checked_at = nil
          resource.activitypub_next_check_at = decision.url.present? ? ExternalResource::ACTIVITYPUB_DUE_AT : nil
          resource.activitypub_evidence_version = 0
        end

        def url_changed?(resource, decision)
          resource.activitypub_candidate_url != decision.url
        end

        def stage_reset!(resource, decision)
          assignment = {
            url: decision.url,
            digest: CandidateCommit.digest(decision.url),
            explicit: decision.explicit,
            version: resource.activitypub_evidence_version,
            previous_digest: resource.activitypub_candidate_digest,
          }
          resource.instance_variable_set(:@activitypub_assignment, assignment)
        end
      end
    end
  end
end
