# frozen_string_literal: true

module PostDrafts
  class Store
    Result = Struct.new(:status, :draft, :error, keyword_init: true) do
      def ok?
        %i(created existing updated deleted).include?(status)
      end
    end

    def initialize(account)
      @account_id = account.id
    end

    def create(client_uuid:, payload:)
      uuid = Payload.client_uuid!(client_uuid)
      normalized = Payload.normalize(payload, owner_account_id: @account_id, client_uuid: uuid)
      write_create(uuid, normalized)
    rescue Payload::Invalid => e
      Result.new(status: :invalid, error: e)
    end

    def update(id, expected_revision:, payload:)
      return invalid_revision unless expected_revision.is_a?(Integer)

      normalized = nil
      outcome = nil
      Account.transaction do
        lock_owner!
        draft = lock_draft(id)
        outcome = missing_or_conflict(draft, expected_revision)
        next if outcome

        normalized = Payload.normalize(payload, owner_account_id: @account_id, client_uuid: draft.client_uuid)
        draft.update!(payload: normalized, schema_version: normalized.fetch('schema_version'), revision: draft.revision + 1)
        outcome = Result.new(status: :updated, draft: draft)
      end
      outcome
    rescue Payload::Invalid => e
      Result.new(status: :invalid, error: e)
    end

    def destroy(id, expected_revision:)
      return invalid_revision unless expected_revision.is_a?(Integer)

      outcome = nil
      Account.transaction do
        lock_owner!
        draft = lock_draft(id)
        outcome = missing_or_conflict(draft, expected_revision)
        next if outcome

        draft.destroy!
        outcome = Result.new(status: :deleted, draft: draft)
      end
      outcome
    end

    private

    def write_create(uuid, normalized)
      outcome = nil
      Account.transaction do
        lock_owner!
        existing = PostDraft.lock.find_by(account_id: @account_id, client_uuid: uuid)
        outcome = create_outcome(existing, uuid, normalized)
      end
      outcome
    rescue ActiveRecord::RecordNotUnique
      reread_create(uuid, normalized)
    end

    def create_outcome(existing, uuid, normalized)
      return duplicate_outcome(existing, normalized) if existing
      return Result.new(status: :limit) if PostDraft.where(account_id: @account_id).count >= PostDraft::LIMIT

      Result.new(status: :created, draft: insert_draft(uuid, normalized))
    end

    def duplicate_outcome(existing, normalized)
      status = Payload.same?(existing.payload, normalized) ? :existing : :conflict
      Result.new(status: status, draft: existing)
    end

    def insert_draft(uuid, normalized)
      PostDraft.create!(
        account_id: @account_id,
        client_uuid: uuid,
        schema_version: normalized.fetch('schema_version'),
        revision: 1,
        state: 'active',
        payload: normalized
      )
    end

    def reread_create(uuid, normalized)
      existing = PostDraft.find_by!(account_id: @account_id, client_uuid: uuid)
      duplicate_outcome(existing, normalized)
    end

    def missing_or_conflict(draft, expected_revision)
      return Result.new(status: :missing) if draft.nil?
      return nil if revision_matches?(draft, expected_revision)

      Result.new(status: :conflict, draft: draft)
    end

    def revision_matches?(draft, expected_revision)
      expected_revision == draft.revision
    end

    def invalid_revision
      Result.new(status: :invalid, error: Payload::Invalid.new([{ 'code' => 'invalid_revision', 'key' => 'expected_revision' }]))
    end

    def lock_owner!
      Account.lock.find(@account_id)
    end

    def lock_draft(id)
      PostDraft.lock.find_by(account_id: @account_id, id: id)
    end
  end
end
