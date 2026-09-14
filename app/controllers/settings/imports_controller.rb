# frozen_string_literal: true

class Settings::ImportsController < Settings::BaseController
  RECENT_FOLLOW_IMPORTS = 10

  before_action :set_account
  before_action :set_follow_import_progress, only: [:show, :create]

  def show
    @import = Import.new
  end

  def create
    @import = Import.new(import_params)
    @import.account = @account

    @import.assign_follow_import_pipeline_version
    if @import.save
      enqueue_import!(@import)
      redirect_to settings_import_path, notice: I18n.t('imports.success')
    else
      render :show
    end
  end

  private

  # Route follow imports straight to their retryable processor (no extra async
  # handoff hop, and nothing destroys the import on an ambiguous enqueue failure);
  # every other import type keeps the plain, retry: false ImportWorker path.
  #
  # The pipeline marker is persisted before ProcessImportWorker.perform_async.
  # It is execution intent ("created by the recovery-aware pipeline"), not
  # executor ownership. Do not enqueue first and write the marker after: a
  # Redis-accepted job with a failed follow-up write would look unmarked.
  def enqueue_import!(import)
    if import.following?
      import.persist_follow_import_pipeline_version!
      FollowImport::ProcessImportWorker.perform_async(import.id)
    else
      ImportWorker.perform_async(import.id)
    end
  end

  def set_account
    @account = current_user.account
  end

  # Unified recent-progress list: recorded batches plus follow Imports that
  # still have no FollowImportBatch. Those Imports are retained through
  # processor retries and watchdog recovery, so absence of a batch is a
  # preparing phase, not "nothing to show" and not completion.
  def set_follow_import_progress
    @follow_import_progress_rows = recent_follow_import_progress_rows
  end

  def recent_follow_import_progress_rows
    progress = FollowImport::ProgressService.new
    rows = recent_follow_import_batches.map do |batch|
      { occurred_at: batch.imported_at, summary: progress.user_summary(batch) }
    end
    rows.concat(pending_follow_imports.map do |import|
      { occurred_at: import.created_at, summary: progress.preparing_summary }
    end)
    rows.sort_by { |row| row[:occurred_at] }.reverse.first(RECENT_FOLLOW_IMPORTS)
  end

  def recent_follow_import_batches
    FollowImportBatch
      .joins(:subject)
      .where(moderation_subjects: { account_id: @account.id })
      .order(imported_at: :desc)
      .limit(RECENT_FOLLOW_IMPORTS)
  end

  # Recovery-aware follow Imports whose processor has not recorded a batch
  # yet (retries, exhaustion, or watchdog re-enqueue). Unmarked leftover
  # rows are not "preparing" — they are not part of this pipeline.
  # Once import_id is on a batch the CSV may still exist until dispatch
  # completes — show the batch, not a second "preparing" row.
  def pending_follow_imports
    Import.where(account: @account)
          .follow_import_recovery_aware
          .without_follow_import_batch
          .order(created_at: :desc)
          .limit(RECENT_FOLLOW_IMPORTS)
  end

  def import_params
    params.require(:import).permit(:data, :type, :mode)
  end
end
