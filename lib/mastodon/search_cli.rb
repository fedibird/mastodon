# frozen_string_literal: true

require_relative '../../config/boot'
require_relative '../../config/environment'
require_relative 'cli_helper'

module Mastodon
  class SearchCLI < Thor
    include CLIHelper

    # Indices are sorted by amount of data to be expected in each, so that
    # smaller indices can go online sooner
    INDICES = [
      AccountsIndex,
      TagsIndex,
      StatusesIndex,
    ].freeze

    option :concurrency, type: :numeric, default: 2, aliases: [:c], desc: 'Workload will be split between this number of threads'
    option :only, type: :array, enum: %w(instances accounts tags statuses), desc: 'Only process these indices'
    option :min, type: :string
    option :max, type: :string
    option :verbose, type: :boolean, default: false, aliases: [:v]
    desc 'deploy', 'Create or upgrade ElasticSearch indices and populate them'
    long_desc <<~LONG_DESC
      If ElasticSearch is empty, this command will create the necessary indices
      and then import data from the database into those indices.

      This command will also upgrade indices if the underlying schema has been
      changed since the last run.

      Even if creating or upgrading indices is not necessary, data from the
      database will be imported into the indices.
    LONG_DESC
    def deploy
      if options[:concurrency] < 1
        say('Cannot run with this concurrency setting, must be at least 1', :red)
        exit(1)
      end

      indices = begin
        if options[:only]
          options[:only].map { |str| "#{str.camelize}Index".constantize }
        else
          [InstancesIndex, *INDICES]
        end
      end

      # Instance's primary key is domain and it has no id or created_at.
      # The generic importer below filters and logs by id, so instances use a separate path.
      id_indices = indices - [InstancesIndex]

      progress = ProgressBar.create(total: nil, format: '%t%c/%u |%b%i| %e (%r docs/s)', autofinish: false)

      # First, ensure all indices are created and have the correct
      # structure, so that live data can already be written
      indices.select { |index| index.specification.changed? }.each do |index|
        progress.title = "Upgrading #{index} "
        index.purge
        index.specification.lock!
      end

      db_config = ActiveRecord::Base.configurations[Rails.env].dup
      db_config['pool'] = options[:concurrency] + 1
      ActiveRecord::Base.establish_connection(db_config)

      pool    = Concurrent::FixedThreadPool.new(options[:concurrency])
      added   = Concurrent::AtomicFixnum.new(0)
      removed = Concurrent::AtomicFixnum.new(0)

      progress.title = 'Estimating workload '

      # Estimate the amount of data that has to be imported first.
      # --min/--max are id bounds and do not apply to InstancesIndex.
      id_indices.each do |index|
        progress.total = (progress.total || 0) + index.adapter.default_scope.where(id: options[:min]..options[:max]).count
      end

      if indices.include?(InstancesIndex)
        progress.total = (progress.total || 0) + InstancesIndex.adapter.default_scope.count
        import_instances_index(progress, pool, added, removed)
      end

      # Now import all the actual data. Mind that unlike chewy:sync, we don't
      # fetch and compare all record IDs from the database and the index to
      # find out which to add and which to remove from the index. Because with
      # potentially millions of rows, the memory footprint of such a calculation
      # is uneconomical. So we only ever add.
      id_indices.each do |index|
        progress.title = "Importing #{index} "
        batch_size     = 1000
        slice_size     = (batch_size / options[:concurrency]).ceil

        index.adapter.default_scope.where(id: options[:min]..options[:max]).reorder(nil).find_in_batches(batch_size: batch_size, order: :desc) do |batch|
          futures = []

          batch.each_slice(slice_size) do |records|
            futures << Concurrent::Future.execute(executor: pool) do
              begin
                if !progress.total.nil? && progress.progress + records.size > progress.total
                  # The number of items has changed between start and now,
                  # since there is no good way to predict the final count from
                  # here, just change the progress bar to an indeterminate one

                  progress.total = nil
                end

                grouped_records = nil
                bulk_body       = nil
                index_count     = 0
                delete_count    = 0

                ActiveRecord::Base.connection_pool.with_connection do
                  grouped_records = index.adapter.send(:grouped_objects, records)
                  grouped_records = {to_index: grouped_records[:index] || [], delete: grouped_records[:delete] || []} unless grouped_records.has_key?(:to_index) && grouped_records.has_key?(:delete)
                  bulk_body       = Chewy::Index::Import::BulkBuilder.new(index, **grouped_records).bulk_body
                end

                index_count  = grouped_records[:to_index].size  if grouped_records.key?(:to_index)
                delete_count = grouped_records[:delete].size    if grouped_records.key?(:delete)

                # The following is an optimization for statuses specifically, since
                # we want to de-index statuses that cannot be searched by anybody,
                # but can't use Chewy's delete_if logic because it doesn't use
                # crutches and our searchable_by logic depends on them
                if index == StatusesIndex
                  bulk_body.map! do |entry|
                    if entry[:to_index] && entry.dig(:to_index, :data, 'searchable_by').blank?
                      index_count  -= 1
                      delete_count += 1

                      { delete: entry[:to_index].except(:data) }
                    else
                      entry
                    end
                  end
                end

                Chewy::Index::Import::BulkRequest.new(index).perform(bulk_body)
                progress.log "#{records.first.created_at} - #{records.last.created_at} ( max: #{records.first.id} - min: #{records.last.id} ) done." if options[:verbose]

                progress.progress += records.size

                added.increment(index_count)
                removed.increment(delete_count)

                sleep 1
              rescue => e
                progress.log pastel.red("Error importing #{index}: #{e} #{records.first.created_at} - #{records.last.created_at} ( max: #{records.first.id} - min: #{records.last.id} )")
              end
            end
          end

          futures.map(&:value)
        end
      end

      progress.title = ''
      progress.stop

      say("Indexed #{added.value} records, de-indexed #{removed.value}", :green, true)
    end

    private

    def import_instances_index(progress, pool, added, removed)
      index      = InstancesIndex
      batch_size = 1000
      slice_size = (batch_size / options[:concurrency]).ceil

      progress.title = "Importing #{index} "

      index.adapter.default_scope.reorder(nil).find_in_batches(batch_size: batch_size) do |batch|
        futures = []

        batch.each_slice(slice_size) do |records|
          futures << Concurrent::Future.execute(executor: pool) do
            begin
              if !progress.total.nil? && progress.progress + records.size > progress.total
                progress.total = nil
              end

              grouped_records = nil
              bulk_body       = nil
              index_count     = 0
              delete_count    = 0

              ActiveRecord::Base.connection_pool.with_connection do
                grouped_records = index.adapter.send(:grouped_objects, records)
                grouped_records = {to_index: grouped_records[:index] || [], delete: grouped_records[:delete] || []} unless grouped_records.has_key?(:to_index) && grouped_records.has_key?(:delete)
                bulk_body       = Chewy::Index::Import::BulkBuilder.new(index, **grouped_records).bulk_body
              end

              index_count  = grouped_records[:to_index].size if grouped_records.key?(:to_index)
              delete_count = grouped_records[:delete].size   if grouped_records.key?(:delete)

              Chewy::Index::Import::BulkRequest.new(index).perform(bulk_body)
              progress.log "#{records.first.domain} - #{records.last.domain} done." if options[:verbose]

              progress.progress += records.size

              added.increment(index_count)
              removed.increment(delete_count)

              sleep 1
            rescue => e
              progress.log pastel.red("Error importing #{index}: #{e} #{records.first.domain} - #{records.last.domain}")
            end
          end
        end

        futures.map(&:value)
      end
    end
  end
end
