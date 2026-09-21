# frozen_string_literal: true

module Settings::ImportsHelper
  # Coarse, user-facing progress. Workflow labels only: no signal,
  # evidence, or moderation reason.
  def follow_import_status_label(summary)
    if summary['stopped']
      t('imports.follow_progress.status.stopped')
    elsif summary['review_pending']
      t('imports.follow_progress.status.waiting_for_review')
    elsif summary['completed']
      t('imports.follow_progress.status.completed')
    elsif summary['preparing']
      t('imports.follow_progress.status.preparing')
    else
      t('imports.follow_progress.status.in_progress')
    end
  end

  def follow_import_processed_label(summary)
    return t('imports.follow_progress.unknown') if summary['preparing']

    t('imports.follow_progress.processed_of', count: summary['processed'], total: summary['total'])
  end

  def follow_import_count_label(summary, key)
    return t('imports.follow_progress.unknown') if summary['preparing']

    number_with_delimiter(summary[key])
  end
end
