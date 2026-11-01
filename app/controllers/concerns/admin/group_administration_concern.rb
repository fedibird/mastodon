# frozen_string_literal: true

module Admin::GroupAdministrationConcern
  extend ActiveSupport::Concern

  PAGE_SIZE = 25

  included do
    after_action :disallow_shared_cache
  end

  private

  def disallow_shared_cache
    private_cache_headers
  end

  # Pundit runs first so verify_authorized passes. The second call is the
  # same rule the services use, so a looser policy cannot open the screen.
  def authorize_group_admin!(record, query)
    authorize record, query
    return if GroupManagement.server_administrator?(current_account)

    raise Mastodon::NotPermittedError
  end

  def private_cache_headers
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Pragma'] = 'no-cache'
  end

  def forbidden
    super
  ensure
    private_cache_headers
  end

  def not_found
    super
  ensure
    private_cache_headers
  end

  def service_unavailable
    super
  ensure
    private_cache_headers
  end

  def group_admin_audits(*targets)
    records = targets.compact
    return Admin::ActionLog.none if records.empty?

    scopes = records.map do |record|
      Admin::ActionLog.unscoped.where(target_type: record.class.name, target_id: record.id)
    end
    scopes.reduce { |combined, scope| combined.or(scope) }.order(id: :desc).limit(20)
  end
end
