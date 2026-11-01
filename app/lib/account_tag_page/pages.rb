# frozen_string_literal: true

module AccountTagPage
  # Software identity for the domains in one status response.
  # Reads cached NodeInfo only. One nodes query for the whole set.
  class Pages
    SOFTWARE_NAME_SQL = <<~SQL.squish.freeze
      CASE
        WHEN nodes.nodeinfo IS NULL OR nodes.nodeinfo->>'error' IS NOT NULL THEN NULL
        ELSE nodes.nodeinfo #>> '{software,name}'
      END
    SQL
    SOFTWARE_VERSION_SQL = <<~SQL.squish.freeze
      CASE
        WHEN nodes.nodeinfo IS NULL OR nodes.nodeinfo->>'error' IS NOT NULL THEN NULL
        ELSE nodes.nodeinfo #>> '{software,version}'
      END
    SQL

    def self.prefetch(statuses)
      software = load_software(remote_domains(statuses))
      new(software)
    rescue StandardError => e
      Rails.logger.warn("Account tag page prefetch skipped: #{e.class}")
      new({})
    end

    def self.empty
      new({})
    end

    def initialize(software)
      @software = software || {}
    end

    def url_for(account, tag)
      return if account.nil? || tag.nil?

      identity = @software[account.domain.to_s.downcase]
      Resolver.call(
        account: account,
        tag: tag,
        software_name: identity && identity[:name],
        software_version: identity && identity[:version]
      )
    rescue StandardError => e
      Rails.logger.warn("Account tag page URL omitted: #{e.class}")
      nil
    end

    class << self
      private

      def load_software(domains)
        domains = Array(domains).uniq
        return {} if domains.empty?

        Node.where(domain: domains).pluck(
          Arel.sql('nodes.domain'),
          Arel.sql(SOFTWARE_NAME_SQL),
          Arel.sql(SOFTWARE_VERSION_SQL)
        ).each_with_object({}) do |(domain, name, version), found|
          next if name.blank? || version.blank?
          next if name.bytesize > 64 || version.bytesize > 128

          found[domain.to_s.downcase] = { name: name, version: version }
        end
      end

      def remote_domains(statuses)
        records = materialize(statuses)
        return [] if records.empty?

        domains = []
        account_ids = []
        nested_status_ids = []
        seen = {}

        records.each { |status| collect(status, domains, account_ids, nested_status_ids, seen) }
        domains.concat(domains_for_nested(nested_status_ids))
        domains.concat(Account.where(id: account_ids.uniq).where.not(domain: nil).pluck(:domain)) if account_ids.any?
        domains.compact.map { |domain| domain.to_s.downcase }.uniq.reject(&:empty?)
      end

      def materialize(statuses)
        return [] if statuses.blank?
        return statuses.to_a if statuses.is_a?(ActiveRecord::Relation)

        list = Array(statuses).compact
        return [] if list.empty?
        return Status.where(id: list).includes(:account).to_a if list.first.is_a?(Integer)

        list.select { |item| item.is_a?(Status) }
      end

      def collect(status, domains, account_ids, nested_status_ids, seen)
        return unless status.is_a?(Status)
        return if seen[status.id]

        seen[status.id] = true
        if status.association(:account).loaded?
          domains << status.account.domain if status.account && !status.account.local?
        elsif status.account_id
          account_ids << status.account_id
        end

        if status.association(:reblog).loaded?
          collect(status.reblog, domains, account_ids, nested_status_ids, seen)
        elsif status.reblog_of_id
          nested_status_ids << status.reblog_of_id
        end

        if status.association(:quote).loaded?
          collect(status.quote, domains, account_ids, nested_status_ids, seen)
        elsif status.quote_id
          nested_status_ids << status.quote_id
        end
      end

      # One query for every unloaded reblog or quote, at any depth. Loaded
      # records are walked in memory and are not selected again. Cycles and
      # ids already seen are skipped.
      def domains_for_nested(status_ids)
        ids = status_ids.compact.uniq
        return [] if ids.empty?

        sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, ids])
          WITH RECURSIVE nest AS (
            SELECT id, account_id, reblog_of_id, quote_id, ARRAY[id] AS path
            FROM statuses
            WHERE id IN (?)
            UNION ALL
            SELECT child.id, child.account_id, child.reblog_of_id, child.quote_id, nest.path || child.id
            FROM statuses child
            INNER JOIN nest ON child.id = nest.reblog_of_id OR child.id = nest.quote_id
            WHERE NOT child.id = ANY(nest.path)
          )
          SELECT DISTINCT accounts.domain
          FROM nest
          INNER JOIN accounts ON accounts.id = nest.account_id
          WHERE accounts.domain IS NOT NULL
        SQL
        ActiveRecord::Base.connection.select_values(sql)
      end
    end
  end
end
