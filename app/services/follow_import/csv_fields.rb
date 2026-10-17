# frozen_string_literal: true

module FollowImport
  # Follow-CSV contract shared by export, the legacy ImportService path, and
  # ImportUnitResolver. BatchExecutionWorker and the scheduler-owned
  # DispatchExecutor both read options through that resolver, so they stay on
  # this same column list.
  #
  # Option keys are the names FollowService already accepts. In particular the
  # "Show boosts" column is :reblogs, not :show_reblogs.
  module CsvFields
    BOOLEAN = ActiveModel::Type::Boolean.new

    # Insertion order is the CSV column order. "Notify on boosts" sits
    # immediately after "Notify on new posts"; the other columns keep their
    # previous relative order.
    COLUMNS = [
      { field: :reblogs,        header: 'Show boosts',         default: true,  boolean: true,  export: ->(follow) { follow.show_reblogs } },
      { field: :notify,         header: 'Notify on new posts', default: false, boolean: true,  export: ->(follow) { follow.notify } },
      { field: :notify_reblogs, header: 'Notify on boosts',    default: false, boolean: true,  export: ->(follow) { follow.notify_reblogs } },
      { field: :languages,      header: 'Languages',           default: nil,   boolean: false, export: ->(follow) { follow.languages&.join(', ') } },
      { field: :delivery,       header: 'Delivery to home',    default: true,  boolean: true,  export: ->(follow) { follow.delivery } },
    ].freeze

    HEADERS = (['Account address'] + COLUMNS.map { |column| column[:header] }).freeze

    module_function

    def headers
      HEADERS
    end

    def row_values(follow)
      COLUMNS.map { |column| column[:export].call(follow) }
    end

    # Missing and blank cells use the column default. Boolean cells are cast
    # with ActiveModel::Type::Boolean so the CSV string "false" is false,
    # not a truthy Ruby string.
    def options_for(row)
      COLUMNS.each_with_object({}) do |column, options|
        options[column[:field]] = read_column(row, column)
      end
    end

    def read_column(row, column)
      text = row[column[:header]]&.strip
      return column[:default] if text.blank?

      if column[:boolean]
        BOOLEAN.cast(text)
      elsif column[:field] == :languages
        text.split(/,\s*/).reject(&:blank?).presence
      else
        text
      end
    end
    private_class_method :read_column
  end
end
