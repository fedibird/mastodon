# frozen_string_literal: true

# Idempotent creator of pending ActionReviewRequest rows.
#
# Creates a snapshot only when a policy decision requires review. The
# decision must be for the same registered operation_type; a mismatch is
# rejected before any pending lookup. It never mutates the underlying
# resource, never changes account moderation state, and never notifies.
# Evidence is caller-supplied and stored as given; this service does not
# infer Follow Import (or any other) evidence.
module ActionReview
  class RequestService
    Result = Struct.new(:requires_review, :request, :created, keyword_init: true) do
      def requires_review?
        requires_review
      end
    end

    def call(operation_type:, actor_account:, resource:, decision:, evaluator_version: nil, evidence: nil) # rubocop:disable Metrics/ParameterLists
      ActionReview::OperationRegistry.fetch!(operation_type)
      unless decision.operation_type.to_s == operation_type.to_s
        raise ArgumentError, "decision operation_type #{decision.operation_type.inspect} does not match #{operation_type.inspect}"
      end

      unless decision.requires_review?
        return Result.new(requires_review: false, request: nil, created: false)
      end

      raise ArgumentError, 'resource must be persisted' if resource.nil? || resource.id.nil?

      existing = existing_pending(operation_type, resource)
      return Result.new(requires_review: true, request: existing, created: false) if existing

      request = ActionReviewRequest.create!(
        operation_type: operation_type.to_s,
        state: :pending,
        actor_account: actor_account,
        resource: resource,
        trigger: decision.trigger,
        signal_level: decision.signal_level,
        policy_mode: decision.policy_mode,
        policy_version: decision.policy_version,
        evaluator_version: evaluator_version,
        reason_codes: Array(decision.reason_codes),
        evidence: snapshot_evidence(evidence),
        requested_at: Time.now.utc
      )

      Result.new(requires_review: true, request: request, created: true)
    rescue ActiveRecord::RecordNotUnique
      Result.new(
        requires_review: true,
        request: existing_pending!(operation_type, resource),
        created: false
      )
    end

    private

    def snapshot_evidence(evidence)
      return {} if evidence.nil?

      evidence
    end

    def resource_scope(operation_type, resource)
      {
        operation_type: operation_type.to_s,
        resource_type: resource.class.base_class.name,
        resource_id: resource.id,
        state: :pending,
      }
    end

    def existing_pending(operation_type, resource)
      ActionReviewRequest.find_by(resource_scope(operation_type, resource))
    end

    def existing_pending!(operation_type, resource)
      ActionReviewRequest.find_by!(resource_scope(operation_type, resource))
    end
  end
end
