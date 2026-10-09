# frozen_string_literal: true

# Usage shown on posting-style cards. Assignments are read once and styles
# are preloaded. Counts are split with availability_status so an unusable
# reference is not counted as a place that still uses the style.
class UserPostingContextAssignment::CardUsage
  PREVIEW_LIMIT = 3

  Entry = Struct.new(:active_count, :unavailable_count, :labels, keyword_init: true) do
    def self.empty
      new(active_count: 0, unavailable_count: 0, labels: [])
    end

    def visible?
      active_count.positive? || unavailable_count.positive?
    end

    def more?
      active_count > labels.size
    end
  end

  def self.for_user(user)
    rows = user.user_posting_context_assignments.includes(:user_posting_context).order(:id).to_a
    grouped = Hash.new { |hash, key| hash[key] = { active: [], unavailable: [] } }

    rows.each do |row|
      style_id = row.user_posting_context_id
      next if style_id.nil?

      bucket = grouped[style_id]
      case row.availability_status
      when 'style'
        bucket[:active] << row
      when 'unavailable'
        bucket[:unavailable] << row
      end
    end

    preview_rows = grouped.each_value.flat_map { |bucket| bucket[:active].first(PREVIEW_LIMIT) }
    catalog = UserPostingContextAssignment::PlaceCatalog.for(user, preview_rows)
    entries = grouped.transform_values do |bucket|
      shown = bucket[:active].first(PREVIEW_LIMIT)
      Entry.new(
        active_count: bucket[:active].size,
        unavailable_count: bucket[:unavailable].size,
        labels: shown.map { |row| summary_label(row, catalog) }
      )
    end
    new(entries)
  end

  def self.summary_label(assignment, catalog)
    name = catalog.label(assignment)
    return name unless catalog.place_available?(assignment)

    I18n.t(
      'user_posting_context_assignments.place_summary',
      kind: I18n.t("user_posting_context_assignments.kinds.#{assignment.surface_kind}"),
      name: name
    )
  end

  def initialize(entries)
    @entries = entries
  end

  def for(context)
    return Entry.empty if context.nil?

    @entries[context.id] || Entry.empty
  end
end
