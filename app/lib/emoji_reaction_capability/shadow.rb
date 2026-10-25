# frozen_string_literal: true

module EmojiReactionCapability
  # Shadow-mode entry points (P1a). Every method is read-only and best effort:
  #
  #   * the legacy code has already chosen and enqueued what it sends before a
  #     method here is called, and nothing here can change it
  #   * the flag is off by default; when off (or when the sample draw misses)
  #     a method returns before any query, Redis call or allocation of note
  #   * no network access, no database write, no job enqueue
  #   * any StandardError is swallowed (and counted, and logged at a bounded
  #     rate) so it can never reach the caller
  #
  # Results are aggregate counters only (ShadowRecorder).
  module Shadow
    WARN_INTERVAL = 60

    module_function

    # Outgoing create for a remote author. legacy_type is what
    # EmojiReactionService enqueued: 'EmojiReact', 'Like' or nil.
    def observe_create(emoji_reaction, legacy_type:)
      observe_single(:create, emoji_reaction, legacy_type)
    end

    # Outgoing Undo for a remote author. legacy_type is what
    # UnEmojiReactionService enqueued.
    def observe_undo(emoji_reaction, legacy_type:)
      observe_single(:undo, emoji_reaction, legacy_type)
    end

    # Local-author fan-out (CustomEmojiDistributionWorker). action is 'create'
    # or 'delete'. Receivers are sampled, never enumerated.
    def observe_fanout(emoji_reaction, action:, now: Time.now.utc)
      return unless ShadowConfig.sample?

      op = action.to_s == 'delete' ? :fanout_delete : :fanout_create
      kind = kind_of(emoji_reaction)
      rows = fanout_sample(emoji_reaction, kind)

      comparisons = Hash.new(0)
      snapshots = Hash.new(0)

      rows.each do |row|
        node = row[:row_present] ? NodeSnapshotLoader.snapshot(row, now: now) : NodeSnapshot.absent
        plan = DeliveryPlan.for_node(node, kind)
        obs = ShadowComparator.compare(op: op, kind: kind, legacy_type: row[:legacy_type], plan: plan, node: node)

        comparisons[ShadowRecorder.comparison_field(obs)] += 1
        snapshots[ShadowRecorder.snapshot_field(:receiver, node)] += 1
      end

      ShadowRecorder.increment(comparisons.merge(snapshots) { |_field, left, right| left + right }, now: now)
    rescue StandardError => e
      record_failure(op || :fanout_create, e)
    end

    def observe_single(operation, emoji_reaction, legacy_type, now: Time.now.utc)
      return unless ShadowConfig.sample?

      status = emoji_reaction.status.proper
      author = status.account
      kind = kind_of(emoji_reaction)

      return if author.local?

      context = status_context(status, author)
      node = needs_node?(context) ? NodeSnapshotLoader.load(author.domain, now: now) : nil
      plan = DeliveryPlan.for_status(context, node, kind)
      obs = ShadowComparator.compare(op: operation, kind: kind, legacy_type: legacy_type, plan: plan, node: node)

      fields = Hash.new(0)
      fields[ShadowRecorder.comparison_field(obs)] += 1
      fields[ShadowRecorder.snapshot_field(:author, node)] += 1 if node

      ShadowRecorder.increment(fields, now: now)
    rescue StandardError => e
      record_failure(operation, e)
    end

    def kind_of(emoji_reaction)
      emoji_reaction.unicode? ? :unicode : :custom
    end

    def status_context(status, author)
      StatusContext.new(
        proper_status_id: status.id,
        author_local: author.local?,
        author_domain: author.domain,
        author_silenced: author.silenced?,
        author_suspended: author.suspended?,
        author_activitypub: author.activitypub?
      )
    end

    def needs_node?(context)
      !context.author_silenced && !context.author_local && context.author_activitypub
    end

    # Bounded, non-random sample of candidate receiver accounts of
    # ActivityPub::CustomEmojiDistributionWorker: a LIMIT on each audience
    # branch (delivery followers of the reactor, remote mentioned accounts). It
    # never evaluates the worker's UNION, which would walk every follower. It is
    # not the set of inboxes actually delivered to (no inbox de-duplication or
    # availability filtering). Then one query joins the sampled
    # accounts to their Node, evaluating the legacy per-receiver outcome in SQL
    # with the same predicates the worker uses. At most three queries, whatever
    # the number of receivers.
    def fanout_sample(emoji_reaction, kind)
      ids = fanout_receiver_ids(emoji_reaction)
      return [] if ids.empty?

      legacy_sql = kind == :unicode ? LEGACY_FANOUT_UNICODE_SQL : LEGACY_FANOUT_CUSTOM_SQL

      Account
        .where(id: ids)
        .where.not(domain: nil)
        .left_joins(:node)
        .limit(ShadowConfig::FANOUT_RECEIVER_SAMPLE)
        .pluck(Arel.sql("#{NodeSnapshotLoader.aliased_select_sql}, #{legacy_sql} AS legacy_type"))
        .map { |values| fanout_row(values) }
    end

    # Remote receivers only, filtered before the LIMIT so local followers
    # cannot exhaust the sample. The budget is split between the follower and
    # mention branches (ceil(N/2) and the rest); unused quota of one branch is
    # given to the other. Still two LIMIT queries, whatever the audience size.
    def fanout_receiver_ids(emoji_reaction)
      status = emoji_reaction.status
      limit = ShadowConfig::FANOUT_RECEIVER_SAMPLE

      followers = status.follower_visibility? ? emoji_reaction.account.delivery_followers.remote.reorder(nil).limit(limit).pluck('accounts.id') : []
      mentions = mention_audience?(status) ? Account.remote.joins(:mentions).merge(status.mentions).limit(limit).pluck('accounts.id') : []

      balanced(followers, mentions, limit)
    end

    def mention_audience?(status)
      status.follower_visibility? || status.limited_visibility? || status.direct_visibility?
    end

    def balanced(first, second, limit)
      quota = (limit / 2.0).ceil
      picked = first.first(quota) + second.first(limit - quota)
      rest = first.drop(quota) + second.drop(limit - quota)

      (picked + rest).uniq.first(limit)
    end

    LEGACY_FANOUT_UNICODE_SQL = <<~SQL.squish
      (CASE WHEN nodes.info->>'emoji_reaction_type' = 'custom' THEN 'Like'
            WHEN nodes.info->>'emoji_reaction_type' = 'unicode' THEN 'EmojiReact' END)
    SQL

    LEGACY_FANOUT_CUSTOM_SQL = <<~SQL.squish
      (CASE WHEN nodes.info->>'emoji_reaction_type' != 'none' THEN 'Like' END)
    SQL

    def fanout_row(values)
      node_row_id, info, info_override, status, last_fetched_at, nodeinfo_missing, legacy_type = values

      {
        row_present: !node_row_id.nil?,
        info: info,
        info_override: info_override,
        status: status,
        last_fetched_at: last_fetched_at,
        nodeinfo_missing: nodeinfo_missing,
        legacy_type: legacy_type,
      }
    end

    def record_failure(operation, error)
      ShadowRecorder.increment({ ShadowRecorder.error_field(operation) => 1 })
      warn_failure(operation, error)
    rescue StandardError
      nil
    end

    # At most one line per error class per minute per process.
    def warn_failure(operation, error)
      @last_warned ||= {}
      key = error.class.name
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_warned[key] && now - @last_warned[key] < WARN_INTERVAL

      @last_warned[key] = now
      Rails.logger.warn("[EmojiReactionCapability::Shadow] #{operation} observation failed: #{error.class}")
    end
  end
end
