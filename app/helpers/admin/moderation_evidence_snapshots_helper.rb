# frozen_string_literal: true

module Admin::ModerationEvidenceSnapshotsHelper
  # Human label for a moderation subject. Prefers the still-attached account's
  # acct; otherwise falls back to the denormalized origin/domain the subject
  # kept, so tombstoned/detached subjects remain identifiable.
  def moderation_subject_label(subject)
    return t('admin.moderation_evidence_snapshots.unknown_subject') if subject.nil?

    if subject.account
      acct = subject.account.local? ? subject.account.username : subject.account.acct
      "@#{acct}"
    elsif subject.domain.present?
      t('admin.moderation_evidence_snapshots.detached_remote_subject', domain: subject.domain)
    else
      t('admin.moderation_evidence_snapshots.detached_local_subject')
    end
  end

  # Link to the subject's account admin page when the account is still attached,
  # otherwise render the plain label (the account is gone).
  def moderation_subject_link(subject)
    label = moderation_subject_label(subject)
    return label if subject.nil? || subject.account.nil?

    link_to label, admin_account_path(subject.account.id)
  end

  def moderation_subject_origin_badge(subject)
    return if subject.nil?

    content_tag(:span, subject.origin, class: "moderation-evidence__badge moderation-evidence__badge--#{subject.origin}")
  end

  # Render a persisted subject-id set as resolved subject links, falling back to
  # the raw id when the subject row is gone (never fabricate identity).
  def moderation_negative_targets(ids, resolved)
    return t('admin.moderation_evidence_snapshots.none') if ids.blank?

    safe_join(ids.map do |id|
      subject = resolved[id]
      subject ? moderation_subject_link(subject) : "##{id}"
    end, ', ')
  end

  def moderation_boolean(value)
    return t('admin.moderation_evidence_snapshots.unknown') if value.nil?

    t("admin.moderation_evidence_snapshots.boolean.#{value ? 'affirmative' : 'negative'}")
  end

  def moderation_snapshot_window(snapshot)
    if snapshot.window_start && snapshot.window_end
      "#{l(snapshot.window_start)} – #{l(snapshot.window_end)}"
    elsif snapshot.window_end
      "… – #{l(snapshot.window_end)}"
    else
      t('admin.moderation_evidence_snapshots.all_time')
    end
  end
end
