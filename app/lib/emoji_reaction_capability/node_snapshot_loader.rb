# frozen_string_literal: true

module EmojiReactionCapability
  # Builds NodeSnapshot values from the database without reading the large
  # nodeinfo / instance_data JSON: the missing-NodeInfo condition of
  # Node#missing? is evaluated by the database.
  module NodeSnapshotLoader
    NODEINFO_MISSING_SQL = "(nodes.nodeinfo IS NULL OR COALESCE(nodes.nodeinfo->>'error' = 'missing', false))"

    module_function

    # One query for any number of domains. Domains without a nodes row map to
    # NodeSnapshot.absent.
    def load_many(domains, now: Time.now.utc)
      domains = Array(domains).compact.uniq
      return {} if domains.empty?

      rows = Node.where(domain: domains)
                 .select(:id, :domain, :info, :info_override, :status, :last_fetched_at, Arel.sql("#{NODEINFO_MISSING_SQL} AS nodeinfo_missing"))
                 .index_by(&:domain)

      domains.index_with do |domain|
        row = rows[domain]
        row ? snapshot(row, now: now) : NodeSnapshot.absent
      end
    end

    def load(domain, now: Time.now.utc)
      load_many([domain], now: now).fetch(domain, NodeSnapshot.absent)
    end

    # One bounded read for a write: the row (or nil) and its snapshot.
    # The select list matches load_many, so nodeinfo and instance_data stay
    # out of the query. No NodeInfo fetch.
    def load_record(domain, now: Time.now.utc)
      return [nil, NodeSnapshot.absent] if domain.blank?

      row = Node.where(domain: domain)
                .select(:id, :domain, :info, :info_override, :status, :last_fetched_at, Arel.sql("#{NODEINFO_MISSING_SQL} AS nodeinfo_missing"))
                .first
      [row, row ? snapshot(row, now: now) : NodeSnapshot.absent]
    end

    # row exposes info, info_override, status, last_fetched_at, nodeinfo_missing.
    def snapshot(row, now: Time.now.utc)
      NodeSnapshot.from_attributes(
        info: row[:info],
        info_override: row[:info_override],
        nodeinfo_missing: row[:nodeinfo_missing],
        status: status_name(row[:status]),
        last_fetched_at: row[:last_fetched_at],
        now: now
      )
    end

    # Columns for a join from accounts (fan-out sample), aliased so they cannot
    # collide with account columns.
    def aliased_select_sql
      [
        'nodes.id AS node_row_id',
        'nodes.info AS info',
        'nodes.info_override AS info_override',
        'nodes.status AS status',
        'nodes.last_fetched_at AS last_fetched_at',
        "#{NODEINFO_MISSING_SQL} AS nodeinfo_missing",
      ].join(', ')
    end

    def status_name(value)
      value.is_a?(Integer) ? Node.statuses.key(value) : value
    end
  end
end
