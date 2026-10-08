# frozen_string_literal: true

module UserPostingContextsHelper
  def user_posting_context_visibility_label(value)
    return t('user_posting_contexts.unset') if value.blank?

    t("statuses.visibilities.#{value}", default: value.to_s)
  end

  def user_posting_context_language_label(value)
    return t('statuses.language_detection') if value.blank?

    name = respond_to?(:human_locale) ? human_locale(value.to_sym) : nil
    name.presence || value.to_s
  end

  def user_posting_context_sensitive_label(value)
    t(value ? 'user_posting_contexts.sensitive_on' : 'user_posting_contexts.sensitive_off')
  end

  def user_posting_context_spoiler_label(value)
    enabled = value.is_a?(Hash) && (value['enabled'] || value[:enabled])
    return t('user_posting_contexts.spoiler_off') unless enabled

    text = value['text'] || value[:text]
    text.presence || t('user_posting_contexts.spoiler_on')
  end

  def user_posting_context_source_label(source)
    t("user_posting_contexts.sources.#{source}", default: source.to_s)
  end

  def user_posting_context_target_label(context)
    case context.target_kind
    when 'hashtag'
      "##{context.target_hashtag}"
    when 'group'
      context.target_account&.acct || t('user_posting_contexts.discovery.missing_group')
    else
      t('user_posting_contexts.target_kinds.none')
    end
  end

  def user_posting_context_summary(context)
    fields = UserPostingContext::Defaults.form_fields(context.defaults)
    parts = [t('user_posting_contexts.summary.visibility', value: summary_visibility(fields))]
    parts << t('user_posting_contexts.summary.language', value: summary_language(fields))
    parts << t('user_posting_contexts.summary.sensitive', value: summary_sensitive(fields))
    tags = UserPostingContext::ManagedHashtags.form_text(context.managed)
    parts << t('user_posting_contexts.summary.hashtags', value: tags.presence || t('user_posting_contexts.no_hashtags'))
    safe_join(parts, ' · ')
  end

  def user_posting_context_visibility_options(context)
    keys = Status.selectable_visibilities
    current = context.visibility_value
    keys |= [current] if current.present? && Status.visibilities.key?(current)
    keys
  end

  def user_posting_context_conflict_text(conflict)
    field = conflict['field'].to_s
    if conflict['kind'] == 'conflict'
      t(
        'user_posting_contexts.conflict_item',
        field: t("user_posting_contexts.preview_labels.#{field}"),
        value: user_posting_context_conflict_value(field, conflict['value']),
        options: Array(conflict['allowed']).map { |value| user_posting_context_conflict_value(field, value) }.join(', ')
      )
    else
      t('user_posting_contexts.unverified_item', field: t("user_posting_contexts.preview_labels.#{field}", default: field))
    end
  end

  def user_posting_context_discovery_explanation(preview)
    reason = preview.discovery_reason.presence
    key = reason if reason.present? && I18n.exists?("user_posting_contexts.discovery.#{reason}")
    key ||= preview.discovery_status if I18n.exists?("user_posting_contexts.discovery.#{preview.discovery_status}")
    t("user_posting_contexts.discovery.#{key || 'unknown'}")
  end

  private

  def user_posting_context_conflict_value(field, value)
    case field
    when 'visibility'
      user_posting_context_visibility_label(value)
    when 'language'
      user_posting_context_language_label(value)
    else
      value.to_s
    end
  end

  def summary_visibility(fields)
    return t('user_posting_contexts.choices.inherit') if fields[:visibility_choice] == 'inherit'

    user_posting_context_visibility_label(fields[:visibility_value])
  end

  def summary_language(fields)
    case fields[:language_choice]
    when 'inherit'
      t('user_posting_contexts.choices.inherit')
    when 'auto'
      t('user_posting_contexts.choices.auto')
    else
      user_posting_context_language_label(fields[:language_code])
    end
  end

  def summary_sensitive(fields)
    return t('user_posting_contexts.choices.inherit') if fields[:sensitive_choice] == 'inherit'

    user_posting_context_sensitive_label(fields[:sensitive_value] == 'true')
  end
end
