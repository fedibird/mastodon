# frozen_string_literal: true

require_relative '../../config/boot'
require_relative '../../config/environment'
require_relative 'cli_helper'

module Mastodon
  class CacheCLI < Thor
    include CLIHelper

    def self.exit_on_failure?
      true
    end

    desc 'clear', 'Clear out the cache storage'
    def clear
      Rails.cache.clear
      say('OK', :green)
    end

    option :concurrency, type: :numeric, default: 5, aliases: [:c]
    option :verbose, type: :boolean, aliases: [:v]
    option :reaction_only, type: :boolean
    option :dirty_only, type: :boolean
    desc 'recount TYPE', 'Update hard-cached counters'
    long_desc <<~LONG_DESC
      Update hard-cached counters of TYPE by counting referenced
      records from scratch. TYPE can be "accounts", "statuses", or
      "emoji-reactions".

      `emoji-reactions` rebuilds only emoji reaction caches. It includes
      statuses that still have reactions, a stored cache or count, or a
      dirty flag, so a cache left behind after reactions were removed is
      repaired too. `--dirty-only` limits that rebuild to dirty rows.

      It may take a very long time to finish, depending on the
      size of the database.
    LONG_DESC
    def recount(type)
      case type
      when 'accounts'
        processed, = parallelize_with_progress(Account.local.includes(:account_stat)) do |account|
          account.recount
        end
      when 'statuses'
        statuses = Status.includes(:status_stat)
        statuses = statuses.joins(:emoji_reactions).distinct if options[:reaction_only]

        processed, = parallelize_with_progress(statuses) do |status|
          status_stat                  = status.status_stat
          status_stat.replies_count    = status.replies.where.not(visibility: :direct).count
          status_stat.reblogs_count    = status.reblogs.count
          status_stat.favourites_count = status.favourites.count
          status_stat.save if status_stat.changed?

          status.refresh_grouped_emoji_reactions!(force: true)
        end
      when 'emoji-reactions'
        processed, = parallelize_with_progress(emoji_reaction_recount_scope) do |status|
          status.refresh_grouped_emoji_reactions!(force: true)
        end
      else
        say("Unknown type: #{type}", :red)
        exit(1)
      end

      say
      say("OK, recounted #{processed} records", :green)
    end

    private

    def emoji_reaction_recount_scope
      if options[:dirty_only]
        return Status.unscoped.where(id: StatusStat.where(emoji_reactions_cache_dirty: true).select(:status_id))
      end

      Status.unscoped.where(<<~SQL.squish)
        statuses.id IN (
          SELECT status_id FROM status_stats
          WHERE emoji_reactions_cache_dirty = TRUE
             OR emoji_reactions_count > 0
             OR emoji_reactions_cache <> ''
          UNION
          SELECT DISTINCT status_id FROM emoji_reactions
        )
      SQL
    end
  end
end
