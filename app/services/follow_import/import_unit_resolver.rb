# frozen_string_literal: true

require 'csv'

# Recovers the per-target follow work — the account address and the per-row
# follow options — for a follow-import batch by reading the import CSV.
#
# Addresses and options are intentionally NOT persisted on the target (privacy /
# no schema change), so they are recovered here on demand, keyed by the same
# canonical FollowImportTarget.key_hash used to record the target. This is ONLY
# an address/option lookup for targets the executor has already claimed from the
# database — chunking and claiming are driven entirely by target state and
# position order, never by slicing this CSV.
#
# FollowImport::BatchExecutionWorker and FollowImport::DispatchExecutor (the
# scheduler-owned path) both call this resolver. Options come from
# FollowImport::CsvFields, the same reader ImportService uses for the legacy
# direct follow import.
module FollowImport
  class ImportUnitResolver
    ROWS_LIMIT = ImportService::ROWS_PROCESSING_LIMIT

    def initialize(import)
      @import = import
    end

    # { target_key_hash => { acct:, options: } } for the whole CSV, deduplicated
    # on the canonical key exactly as the recorder deduplicated the target set.
    def work_by_key_hash
      @work_by_key_hash ||= build
    end

    # Convenience: the recovered work for one claimed target, or nil.
    def work_for(target)
      work_by_key_hash[target.target_key_hash]
    end

    private

    def build
      return {} if @import.nil?

      local_suffix = "@#{Rails.configuration.x.local_domain}"

      rows.each_with_object({}) do |row, map|
        acct = row['Account address']&.strip&.delete_suffix(local_suffix)
        next if acct.blank?

        key = FollowImportTarget.key_hash(acct)
        next if key.nil? || map.key?(key)

        options = CsvFields.options_for(row)

        map[key] = { acct: acct, options: options }
      end
    end

    def rows
      data = CSV.parse(csv_text, headers: true)
      data = CSV.parse(csv_text, headers: ['Account address']) unless data.headers&.first&.strip&.include?(' ')
      data.reject(&:blank?).take(ROWS_LIMIT)
    end

    def csv_text
      Paperclip.io_adapters.for(@import.data).read
    end
  end
end
