# frozen_string_literal: true

module Admin
  # Read-only view over the moderation evidence ledger: the point-in-time
  # snapshots captured when a moderator action is taken. This surfaces the
  # recorded reasoning (summary counts, coverage, linked/correlated negative
  # target sets) for later review. It never scores, judges, or mutates the
  # ledger.
  class ModerationEvidenceSnapshotsController < BaseController
    before_action :set_snapshot, only: [:show]

    PER_PAGE = 25

    def index
      authorize :moderation_evidence_snapshot, :index?

      # A narrowing parameter must fail closed: a stale/invalid subject_id 404s
      # (via rescue_from RecordNotFound) rather than silently widening to the
      # global snapshot list.
      @subject   = ModerationSubject.find(params[:subject_id]) if params[:subject_id].present?
      @snapshots = filtered_snapshots
                   .includes(subject: :account, moderation_actions: :moderator_account)
                   .order(created_at: :desc)
                   .page(params[:page])
                   .per(PER_PAGE)
    end

    def show
      authorize @snapshot, :show?

      @moderation_actions  = @snapshot.moderation_actions.includes(:moderator_account).order(performed_at: :desc)
      @linked_subjects     = resolve_subjects(@snapshot.linked_negative_target_subject_ids)
      @correlated_subjects = resolve_subjects(@snapshot.correlated_negative_target_subject_ids)
    end

    private

    def set_snapshot
      @snapshot = ModerationEvidenceSnapshot.includes(subject: :account).find(params[:id])
    end

    def filtered_snapshots
      scope = ModerationEvidenceSnapshot.all
      scope = scope.where(subject_id: @subject.id) if @subject
      scope
    end

    # Resolve the persisted subject-id sets to their subjects (and accounts when
    # still attached) for display, without ever fabricating a missing subject.
    def resolve_subjects(ids)
      return {} if ids.blank?

      ModerationSubject.where(id: ids).includes(:account).index_by(&:id)
    end
  end
end
