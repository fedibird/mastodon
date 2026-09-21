# frozen_string_literal: true

# Pure policy decision: given a registered operation, site intervention
# mode, and optional automated signal, should a human review the action?
#
# This is review-intervention sensitivity, not a danger scale, guilt
# score, identity judgment, or moderation action. Evaluator errors under
# an active threshold policy route toward review (moderator queue), never
# automatic rejection.
module ActionReview
  class PolicyDecisionService
    POLICY_VERSION = 'action-review-policy-v1'

    TRIGGER_NONE = 'none'
    TRIGGER_POLICY = 'policy'
    TRIGGER_EVALUATOR_UNAVAILABLE = 'evaluator_unavailable'

    EVALUATION_OK = 'ok'

    THRESHOLDS = {
      'off' => [].freeze,
      'high' => %w(high).freeze,
      'medium' => %w(medium high).freeze,
      'low' => %w(low medium high).freeze,
      'always' => ActionReview::OperationRegistry::SIGNAL_LEVELS,
    }.freeze

    Result = Struct.new(
      :operation_type,
      :policy_mode,
      :signal_level,
      :evaluation_status,
      :requires_review,
      :trigger,
      :policy_version,
      :reason_codes,
      keyword_init: true
    ) do
      def requires_review?
        requires_review
      end
    end

    def call(operation_type:, signal_level: 'none', evaluation_status: EVALUATION_OK, policy_mode: nil)
      ActionReview::OperationRegistry.fetch!(operation_type)
      mode = resolve_mode(operation_type, policy_mode)
      signal = normalize_signal(signal_level)
      status = evaluation_status.to_s
      review, trigger, reasons = decide(mode, signal, status)

      Result.new(
        operation_type: operation_type.to_s,
        policy_mode: mode,
        signal_level: signal,
        evaluation_status: status,
        requires_review: review,
        trigger: trigger,
        policy_version: POLICY_VERSION,
        reason_codes: reasons
      )
    end

    private

    def resolve_mode(operation_type, policy_mode)
      if policy_mode.nil?
        ActionReview::PolicySettings.mode_for(operation_type)
      else
        ActionReview::PolicySettings.normalize_mode(policy_mode)
      end
    end

    def normalize_signal(signal_level)
      text = signal_level.to_s.strip.downcase
      return text if ActionReview::OperationRegistry::SIGNAL_LEVELS.include?(text)

      raise ArgumentError, "unknown action review signal_level: #{signal_level.inspect}"
    end

    def decide(mode, signal, status)
      if status == EVALUATION_OK
        decide_ok(mode, signal)
      else
        decide_evaluator_error(mode)
      end
    end

    def decide_ok(mode, signal)
      if THRESHOLDS.fetch(mode).include?(signal)
        [true, TRIGGER_POLICY, reason_codes_for(mode, signal)]
      else
        [false, TRIGGER_NONE, []]
      end
    end

    def decide_evaluator_error(mode)
      case mode
      when 'off'
        [false, TRIGGER_NONE, []]
      when 'always'
        [true, TRIGGER_POLICY, %w(policy_always evaluator_unavailable)]
      else
        [true, TRIGGER_EVALUATOR_UNAVAILABLE, %w(evaluator_unavailable)]
      end
    end

    def reason_codes_for(mode, signal)
      codes = ["policy_#{mode}"]
      codes << "signal_#{signal}" unless signal == 'none'
      codes
    end
  end
end
