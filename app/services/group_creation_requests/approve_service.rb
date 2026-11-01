# frozen_string_literal: true

module GroupCreationRequests
  # Approves one pending request. The reviewer is checked here, not only in
  # an HTTP filter. The request row is locked, then the group Account,
  # ManagedGroup, owner role, invite-policy snapshot, approved request, and
  # audit row commit together. A staged icon is revalidated before that
  # insert and copied only after commit. No follow is created.
  class ApproveService
    def self.call(request:, reviewer_account:)
      new(request, reviewer_account).call
    end

    def initialize(request, reviewer_account)
      @request = request
      @reviewer_account = reviewer_account
    end

    def call
      raise DecisionError, :feature_disabled unless Feature.enabled?
      raise DecisionError, :not_authorized unless GroupManagement.server_administrator?(@reviewer_account)

      outcome = nil
      GroupCreationRequest.transaction do
        outcome = approve_locked!
      end
      enqueue_icon_handoff
      outcome
    rescue DecisionError => e
      DecisionResult.new(request: reload_request, code: e.code)
    rescue ActiveRecord::RecordNotUnique => e
      DecisionResult.new(request: reload_request, code: unique_code(e))
    rescue ActiveRecord::RecordInvalid => e
      DecisionResult.new(request: reload_request, code: invalid_code(e))
    end

    private

    def approve_locked!
      @request.lock!
      raise DecisionError, :not_pending unless @request.pending?
      raise DecisionError, :feature_disabled unless Feature.enabled?
      raise DecisionError, :not_authorized unless GroupManagement.server_administrator?(@reviewer_account)
      raise DecisionError, :invalid_requester unless GroupManagement.local_functional_person?(@request.requester_account)

      icon_code = staged_icon_code
      raise DecisionError, icon_code if icon_code
      raise DecisionError, :username_taken unless @request.username_available_for_approval?

      group = insert_group!
      DecisionResult.new(request: @request, group_account: group, code: :approved)
    end

    def staged_icon_code
      return if @request.icon_storage_key.blank?

      GroupCreationIcons::Revalidation.call(@request).code
    end

    def insert_group!
      group = Account.create!(
        username: @request.username,
        display_name: @request.display_name,
        note: @request.note,
        actor_type: 'Group',
        discoverable: true
      )
      group.account_stat.save! if group.account_stat.new_record?
      managed = ManagedGroup.create!(account: group, origin: :approved_request, creation_request: @request)
      GroupRoleAssignment.create!(
        group_account: group,
        member_account: @request.requester_account,
        role: :owner,
        granted_by_account: @reviewer_account,
        granted_at: Time.current
      )
      GroupRegistrationInvitePolicy.copy_site_defaults!(managed_group: managed)
      @request.record_approval!(reviewer_account: @reviewer_account, group_account: group)
      GroupCreationDecision.record!(@request)
      group
    end

    # The approval is already committed. A Redis or Sidekiq outage must not
    # look like a failed approval: a second call would only return
    # not_pending. The hourly handoff recovery copies the icon later.
    def enqueue_icon_handoff
      return if @request.icon_storage_key.blank? || @request.icon_purged_at.present?

      GroupCreationIcons::HandoffWorker.perform_async(@request.id)
    rescue StandardError => e
      Rails.logger.error("Group creation icon enqueue failed request_id=#{@request.id} error=#{e.class}")
      record_enqueue_failure
    end

    def record_enqueue_failure
      @request.update!(
        icon_handoff_error: 'enqueue_failed',
        icon_handoff_failed_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("Group creation icon enqueue record failed request_id=#{@request.id} error=#{e.class}")
    end

    def reload_request
      GroupCreationRequest.find(@request.id)
    end

    def unique_code(error)
      return :username_taken if error.message.to_s.include?('index_accounts_on_username_and_domain_lower')

      :conflict
    end

    def invalid_code(error)
      record = error.record
      return :username_taken if record.is_a?(Account) && record.errors.of_kind?(:username, :taken)
      return :invalid_requester if record.is_a?(GroupRoleAssignment) && record.errors.of_kind?(:member_account, :invalid)
      return :not_authorized if record.is_a?(GroupCreationRequest) && record.errors.of_kind?(:reviewer_account, :invalid)
      return :not_pending if record.is_a?(GroupCreationRequest) && record.errors.of_kind?(:state, :invalid)

      :conflict
    end
  end
end
