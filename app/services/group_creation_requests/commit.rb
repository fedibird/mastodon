# frozen_string_literal: true

module GroupCreationRequests
  # Turns a confirmed draft into a pending GroupCreationRequest.
  # requester and state come from the signed-in account and the model
  # default, not from the draft's free-form fields beyond the snapshot
  # the server itself stored.
  class Commit
    Result = Struct.new(:request, :status, keyword_init: true)

    def self.call(requester_account:, draft:)
      new(requester_account, draft).call
    end

    def initialize(requester_account, draft)
      @requester_account = requester_account
      @draft = draft
    end

    def call
      request = build_request
      return Result.new(request: request, status: :invalid) if request.errors.any?

      saved = save_request(request)
      return Result.new(request: request, status: :invalid) unless saved

      Result.new(request: request, status: :created)
    rescue ActiveRecord::RecordNotUnique
      existing = find_existing
      return Result.new(request: existing, status: :duplicate) if existing

      Result.new(request: request, status: :invalid)
    rescue ActiveRecord::RecordInvalid
      Result.new(request: request, status: :invalid)
    end

    private

    def build_request
      request = @requester_account.group_creation_requests.new(
        username: @draft['username'],
        display_name: @draft['display_name'],
        note: @draft['note'],
        submission_token: @draft['submission_token']
      )
      attach_icon(request)
      request.valid? if request.errors.empty?
      request
    end

    def attach_icon(request)
      key = @draft['icon_storage_key']
      return if key.blank?

      bytes = GroupCreationIcons::Storage.resolve.read(key)
      inspection = GroupCreationIcons::Inspector.call(StringIO.new(bytes))
      unless inspection.ok? && inspection.mime == @draft['icon_content_type'] && inspection.byte_size == integer_size
        request.errors.add(:base, I18n.t('group_creation_requests.icon_errors.corrupt'))
        return
      end

      request.icon_storage_key = key
      request.icon_content_type = inspection.mime
      request.icon_byte_size = inspection.byte_size
    rescue GroupCreationIcons::NotFound
      request.errors.add(:base, I18n.t('group_creation_requests.icon_errors.missing'))
    rescue GroupCreationIcons::ConfigurationError
      request.errors.add(:base, I18n.t('group_creation_requests.icon_errors.storage_unavailable'))
    end

    def save_request(request)
      saved = false
      GroupCreationRequest.transaction do
        attach_previous(request)
        if request.errors.any?
          raise ActiveRecord::Rollback
        else
          request.save!
          saved = true
        end
      end
      saved
    end

    def attach_previous(request)
      raw = @draft['previous_request_id']
      return if raw.blank?

      previous_id = coerce_integer(raw)
      previous = @requester_account.group_creation_requests.lock.find_by(id: previous_id) if previous_id
      if previous.nil? || !(previous.rejected? || previous.cancelled?) || previous.successor_request.present?
        request.errors.add(:previous_request_id, :invalid)
        return
      end

      request.previous_request = previous
    end

    def integer_size
      coerce_integer(@draft['icon_byte_size'])
    end

    def coerce_integer(raw)
      return raw if raw.is_a?(Integer)

      Integer(raw, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def find_existing
      token = @draft['submission_token']
      scope = @requester_account.group_creation_requests
      found = scope.find_by(submission_token: token) if token.present?
      return found if found

      key = @draft['icon_storage_key']
      scope.find_by(icon_storage_key: key) if key.present?
    end
  end
end
