# frozen_string_literal: true

module EmojiReactionCapability
  # Aggregate-only measurement store: one Redis hash per UTC hour with a TTL.
  # Fields are built from closed vocabularies (every value is sanitized to a
  # whitelist or 'other'), so cardinality is bounded by construction. Nothing
  # per account, per status, per domain, or any emoji name is written.
  # Writes are best effort and never raise.
  module ShadowRecorder
    KEY_PREFIX = 'emoji_reaction_shadow:v1'
    RETENTION = 8.days

    FAMILIES = (NodeSnapshot::KNOWN_FAMILIES + %w(birdsitelive kmyblue misskey other unknown none)).freeze
    NODE_STATES = %w(known no_row nodeinfo_missing unknown_type not_read).freeze
    KINDS = %w(unicode custom).freeze
    RESULTS = %w(match diff).freeze
    REACHABILITY = %w(up gone unknown).freeze

    extend Redisable

    module_function

    def key_for(time)
      "#{KEY_PREFIX}:#{time.utc.strftime('%Y%m%d%H')}"
    end

    def comparison_field(obs)
      [
        'cmp',
        "op=#{pick(obs[:op], ShadowComparator::OPS)}",
        "kind=#{pick(obs[:kind], KINDS)}",
        "family=#{pick(obs[:family], FAMILIES)}",
        "node=#{pick(obs[:node], NODE_STATES)}",
        "legacy=#{pick(obs[:legacy], ShadowComparator::TYPES)}",
        "proposed=#{pick(obs[:proposed], ShadowComparator::TYPES)}",
        "basis=#{pick(obs[:basis], DeliveryPlan::BASES.map(&:to_s))}",
        "result=#{pick(obs[:result], RESULTS)}",
      ].join('|')
    end

    def snapshot_field(source, node)
      [
        'snap',
        "src=#{source == :receiver ? 'receiver' : 'author'}",
        "node=#{pick(node.state, NODE_STATES)}",
        "family=#{pick(node.family, FAMILIES)}",
        "reach=#{pick(node.reachability.to_s, REACHABILITY)}",
        "stale=#{node.stale ? 1 : 0}",
        "override=#{node.admin_override ? 1 : 0}",
        "stale_ignored=#{node.stale_info_ignored ? 1 : 0}",
      ].join('|')
    end

    def error_field(operation)
      "err|op=#{pick(operation.to_s, ShadowComparator::OPS)}"
    end

    # fields: { 'field' => count }
    def increment(fields, now: Time.now.utc)
      return if fields.empty?

      key = key_for(now)

      with_redis do |conn|
        conn.pipelined do |pipeline|
          fields.each { |field, count| pipeline.hincrby(key, field, count) }
          pipeline.expire(key, RETENTION.to_i)
        end
      end
    end

    def pick(value, allowed)
      allowed.include?(value.to_s) ? value.to_s : 'other'
    end
  end
end
