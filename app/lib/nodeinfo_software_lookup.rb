# frozen_string_literal: true

# Reads the cached NodeInfo software name and version for account domains.
# UpdateNodeService is not called. A missing row, a NodeInfo error document,
# or a lookup failure yields nil so account JSON still renders.
class NodeInfoSoftwareLookup
  # nodeinfo->>'error' covers both a missing document and a fetch error.
  # The `?` jsonb operator is avoided because ActiveRecord treats `?` as a bind.
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
  WALKED_ASSOCIATIONS = %i(account reblog status from_account).freeze
  NAME_LIMIT = 64
  VERSION_LIMIT = 128
  private_constant :SOFTWARE_NAME_SQL, :SOFTWARE_VERSION_SQL, :WALKED_ASSOCIATIONS, :NAME_LIMIT, :VERSION_LIMIT

  class Cache < ActiveSupport::CurrentAttributes
    attribute :entries
  end

  module CollectionPreload
    def serializable_hash(*)
      NodeInfoSoftwareLookup.preload_records(object)
      super
    end
  end

  class << self
    def read(domain)
      key = normalize_domain(domain)
      return if key.nil?

      cache = entries
      return cache[key] if cache.key?(key)

      preload([key])
      entries[key]
    end

    def preload(domains)
      cache = entries
      needed = Array(domains).filter_map { |domain| normalize_domain(domain) }.uniq.reject { |domain| cache.key?(domain) }
      return if needed.empty?

      found = fetch(needed)
      needed.each { |domain| cache[domain] = found[domain] }
    rescue StandardError
      needed&.each { |domain| entries[domain] = nil }
      nil
    end

    # Uses associations that are already loaded. It does not fetch NodeInfo
    # and it does not load an association that the caller did not preload.
    def preload_records(records)
      return unless records.respond_to?(:each)

      preload(domains_from_records(records))
    rescue StandardError
      nil
    end

    def reset!
      Cache.reset
    end

    private

    def entries
      Cache.entries ||= {}
    end

    def fetch(domains)
      rows = Node.where(domain: domains).pluck(
        Arel.sql('nodes.domain'),
        Arel.sql(SOFTWARE_NAME_SQL),
        Arel.sql(SOFTWARE_VERSION_SQL)
      )
      rows.each_with_object({}) do |(domain, name, version), found|
        found[domain] = identity(domain, name, version)
      end
    end

    def identity(domain, name, version)
      software_name = name.to_s.strip
      software_version = version.to_s.strip
      return if software_name.empty? || software_version.empty?
      return if software_name.bytesize > NAME_LIMIT || software_version.bytesize > VERSION_LIMIT

      { 'name' => software_name, 'version' => software_version, 'domain' => domain }
    end

    def domains_from_records(records)
      seen = {}.compare_by_identity
      domains = []
      records.each { |record| collect_domains(record, seen, domains) }
      domains
    end

    def collect_domains(record, seen, domains)
      return unless record.is_a?(ActiveRecord::Base)
      return if seen[record]

      seen[record] = true
      domains << record.domain if record.is_a?(Account) && record.domain.present?
      WALKED_ASSOCIATIONS.each do |name|
        next unless record.class.reflect_on_association(name)
        next unless record.association(name).loaded?

        collect_domains(record.public_send(name), seen, domains)
      end
    end

    def normalize_domain(domain)
      value = domain.to_s.strip.downcase
      return if value.empty? || value.bytesize > 253
      return unless value.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/)

      value
    end
  end
end
