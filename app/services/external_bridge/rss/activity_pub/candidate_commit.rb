# frozen_string_literal: true

module ExternalBridge
  module RSS
    module ActivityPub
      # One UPDATE replaces the candidate URL and clears object evidence.
      # Callers hold the row lock. The version and digest predicates reject a
      # probe that still has the previous candidate.
      class CandidateCommit
        def self.digest(url)
          ExternalResource.digest_activitypub_candidate(url)
        end

        def self.call!(record, assignment)
          updated = record.class.where(id: record.id, activitypub_evidence_version: assignment[:version])
                          .where('activitypub_candidate_digest IS NOT DISTINCT FROM ?', assignment[:previous_digest])
                          .update_all(columns(assignment))
          raise ActiveRecord::StaleObjectError.new(record, 'activitypub_candidate') if updated != 1

          record.reload
        end

        def self.columns(assignment)
          url = assignment[:url]
          {
            activitypub_candidate_url: url,
            activitypub_candidate_digest: assignment[:digest],
            activitypub_explicit: assignment[:explicit],
            activitypub_state: 'unknown',
            activitypub_object_id: nil,
            activitypub_object_id_status: nil,
            activitypub_object_type: nil,
            activitypub_checked_at: nil,
            activitypub_next_check_at: url.present? ? ExternalResource::ACTIVITYPUB_DUE_AT : nil,
            activitypub_evidence_version: assignment[:version].to_i + 1,
            updated_at: Time.current,
          }
        end
      end
    end
  end
end
