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
    # Status has no maximum reblog or quote depth. Each id is fetched once.
    # A long chain or a wide shared-child graph stops here; domains past the
    # cap are omitted and the status response still renders.
    MAX_NESTED_DEPTH = 8
    MAX_NESTED_IDS = 200
    private_constant :SOFTWARE_NAME_SQL, :SOFTWARE_VERSION_SQL, :MAX_NESTED_DEPTH, :MAX_NESTED_IDS

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
        domains.concat(domains_for_nested(nested_status_ids, seen))
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

      # Breadth-first by id. A shared child is selected once, not once per path.
      # Past MAX_NESTED_DEPTH or MAX_NESTED_IDS the rest are left unresolved.
      def domains_for_nested(status_ids, seen)
        pending = status_ids.compact.uniq.reject { |id| seen[id] }
        return [] if pending.empty?

        account_ids = []
        depth = 0
        fetched = 0
        truncated = false

        while pending.any? && depth < MAX_NESTED_DEPTH && fetched < MAX_NESTED_IDS
          unseen = pending.uniq.reject { |id| seen[id] }
          batch = unseen.take(MAX_NESTED_IDS - fetched)
          truncated ||= unseen.size > batch.size
          break if batch.empty?

          rows = Status.where(id: batch).pluck(:id, :account_id, :reblog_of_id, :quote_id)
          found = rows.to_h { |id, account_id, reblog_id, quote_id| [id, [account_id, reblog_id, quote_id]] }
          depth += 1
          next_ids = []
          follow = depth < MAX_NESTED_DEPTH && (fetched + batch.size) < MAX_NESTED_IDS

          batch.each do |id|
            seen[id] = true
            fetched += 1
            account_id, reblog_id, quote_id = found[id]
            account_ids << account_id if account_id
            children = [reblog_id, quote_id].compact.reject { |child_id| seen[child_id] }
            if follow
              next_ids.concat(children)
            else
              truncated ||= children.any?
            end
          end

          pending = next_ids
        end

        Rails.logger.warn("Account tag page nested walk stopped depth=#{depth} ids=#{fetched}") if truncated

        return [] if account_ids.empty?

        Account.where(id: account_ids.uniq).where.not(domain: nil).pluck(:domain)
      end
    end
  end
end
