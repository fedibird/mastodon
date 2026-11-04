# frozen_string_literal: true

# Writes GroupDirectoryIndex documents with an external version.
#
# The version is the Redis counter bumped when an id is enqueued. A writer
# reloads the row and records the version before and after that read. It
# writes only when those versions match, and Elasticsearch rejects a write
# whose version is not strictly newer than the stored one. A backfill that
# still holds an older snapshot cannot replace a document a live worker has
# already published.
#
# `tootctl search deploy` never removes a document for a group that left the
# directory. `rebuild!` purges this index only, refills it from the current
# eligible rows, and then applies ids still waiting in Redis so a hide that
# happened during the rebuild is deleted.
class GroupDirectory::Import
  Result = Struct.new(:indexed, :deleted, :rejected, keyword_init: true)
  Snapshot = Struct.new(:id, :version, :account, keyword_init: true)

  # In-memory stand-in for the external-version rule. Tests use it so a
  # stale write can be rejected without a cluster.
  class MemoryIndex
    def initialize
      @docs = {}
      @versions = {}
    end

    def clear
      @docs.clear
      @versions.clear
    end

    def document(id)
      @docs[id.to_s]
    end

    def apply(id:, version:, document:)
      current = @versions[id.to_s]
      return :rejected if current && version.to_i <= current

      if document.nil?
        @docs.delete(id.to_s)
      else
        @docs[id.to_s] = document
      end
      @versions[id.to_s] = version.to_i
      :written
    end
  end

  class << self
    def call(ids, index: nil)
      ids = normalize(ids)
      return Result.new(indexed: 0, deleted: 0, rejected: 0) if ids.empty?

      snapshots = stable_snapshots(ids)
      write(snapshots, index)
    end

    def rebuild!(index: nil)
      if index
        index.clear
      else
        GroupDirectoryIndex.purge
        GroupDirectoryIndex.specification.lock!
      end

      GroupDirectory::Eligibility.scope.in_batches(of: GroupDirectory::Indexing::BATCH_SIZE) do |batch|
        call(batch.pluck(:id), index: index)
      end
      waiting = GroupDirectory::Indexing.outstanding_ids
      call(waiting, index: index) if waiting.any?
    end

    private

    def normalize(ids)
      Array(ids).flatten.compact.map { |id| id.to_i.to_s }.select { |id| id.to_i.positive? }.uniq
    end

    def stable_snapshots(ids)
      remaining = ids.dup
      ready = []
      5.times do
        break if remaining.empty?

        before = read_versions(remaining)
        accounts = listed_accounts(remaining)
        after = read_versions(remaining)
        stable, remaining = remaining.partition { |id| before[id] == after[id] }
        stable.each do |id|
          version = before[id]
          if version.zero?
            unless claim_baseline_version(id)
              remaining << id
              next
            end
            version = 1
            accounts = accounts.merge(listed_accounts([id]))
          end
          ready << Snapshot.new(id: id, version: version, account: accounts[id])
        end
      end
      GroupDirectory::Indexing.push(remaining) if remaining.any?
      ready
    end

    def listed_accounts(ids)
      GroupDirectory::Eligibility.scope.where(id: ids).index_by { |account| account.id.to_s }
    end

    def claim_baseline_version(id)
      return false unless redis.hsetnx(GroupDirectory::Indexing::VERSIONS_KEY, id, 1)

      read_versions([id])[id] == 1
    end

    def read_versions(ids)
      values = redis.hmget(GroupDirectory::Indexing::VERSIONS_KEY, ids)
      ids.zip(values).to_h { |id, value| [id, value.to_i] }
    end

    def write(snapshots, index)
      result = Result.new(indexed: 0, deleted: 0, rejected: 0)
      return result if snapshots.empty?

      if index
        write_memory(snapshots, index, result)
      else
        write_elasticsearch(snapshots, result)
      end
      result
    end

    def write_memory(snapshots, index, result)
      snapshots.each do |snapshot|
        outcome = index.apply(id: snapshot.id, version: snapshot.version, document: document_for(snapshot))
        count_outcome(result, snapshot, outcome)
      end
    end

    def write_elasticsearch(snapshots, result)
      body = snapshots.flat_map { |snapshot| bulk_entry(snapshot) }
      response = Chewy.client.bulk(body: body)
      Array(response['items']).each_with_index do |item, index|
        action, payload = item.first
        status = payload['status'].to_i
        snapshot = snapshots[index]
        if status == 409
          result.rejected += 1
        elsif status == 404 && action.to_s == 'delete'
          result.deleted += 1
        elsif status >= 300
          raise "Group directory index bulk failed for #{snapshot.id}: #{status}"
        elsif action.to_s == 'delete'
          result.deleted += 1
        else
          result.indexed += 1
        end
      end
    end

    def count_outcome(result, snapshot, outcome)
      if outcome == :rejected
        result.rejected += 1
      elsif snapshot.account
        result.indexed += 1
      else
        result.deleted += 1
      end
    end

    def bulk_entry(snapshot)
      meta = { _index: GroupDirectoryIndex.index_name, _id: snapshot.id, version: snapshot.version, version_type: 'external' }
      if snapshot.account
        [{ index: meta }, document_for(snapshot)]
      else
        [{ delete: meta }]
      end
    end

    def document_for(snapshot)
      return if snapshot.account.nil?

      GroupDirectoryIndex.compose(snapshot.account).deep_stringify_keys
    end

    def redis
      GroupDirectory::Indexing.redis
    end
  end
end
