# frozen_string_literal: true

# Causality rules for linking a rejection to the contact it responded to.
#
# Same-window overlap of "A contacted B" and "B rejected A" is not enough to
# treat B as a negative target. A rejection is causally linked only when:
#
#   * it occurred at or after the candidate interaction;
#   * the interaction is A → B and the rejection is B → A;
#   * the elapsed time is within MAX_WINDOW.
#
# Preferred evidence is +preceding_interaction_event_id+ (populated by
# Moderation::EventRecorder). Unlinked same-window overlap is retained as a
# weaker correlation and must not be stored in +negative_target_subject_ids+.
module Moderation
  module Causality
    MAX_WINDOW = 14.days

    module_function

    def valid_link?(interaction, rejection)
      return false if rejection.nil?

      valid_pair?(
        interaction,
        rejected_subject_id: rejection.rejected_subject_id,
        rejector_subject_id: rejection.rejector_subject_id,
        occurred_at: rejection.occurred_at
      )
    end

    def valid_pair?(interaction, rejected_subject_id:, rejector_subject_id:, occurred_at:)
      return false if interaction.nil? || occurred_at.nil?
      return false unless interaction.actor_subject_id == rejected_subject_id
      return false unless interaction.target_subject_id == rejector_subject_id
      return false if interaction.occurred_at.nil?
      return false if occurred_at < interaction.occurred_at

      (occurred_at - interaction.occurred_at) <= MAX_WINDOW
    end

    def find_preceding_interaction(rejected_subject:, rejector_subject:, occurred_at:)
      return if rejected_subject.nil? || rejector_subject.nil? || occurred_at.nil?

      ModerationInteractionEvent
        .where(actor_subject_id: rejected_subject.id, target_subject_id: rejector_subject.id)
        .where('occurred_at <= ?', occurred_at)
        .where('occurred_at >= ?', occurred_at - MAX_WINDOW)
        .order(occurred_at: :desc, id: :desc)
        .first
    end
  end
end
