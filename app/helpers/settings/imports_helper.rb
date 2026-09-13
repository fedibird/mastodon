# frozen_string_literal: true

module Settings::ImportsHelper
  # Coarse, user-facing progress for a follow-import batch (no internal state /
  # gate / risk detail).
  def follow_import_progress(batch)
    FollowImport::ProgressService.new.user_summary(batch)
  end

  def follow_import_status_label(summary)
    if summary['completed']
      t('imports.follow_progress.status.completed')
    else
      t('imports.follow_progress.status.in_progress')
    end
  end
end
