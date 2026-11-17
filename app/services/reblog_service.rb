# frozen_string_literal: true

class ReblogService < BaseService
  include Authorization

  # Reblog a status and notify its remote author
  # @param [Account] account Account to reblog from
  # @param [Status] reblogged_status Status to be reblogged
  # @param [Hash] options
  # @option [String]  :visibility
  # @option [Boolean] :with_rate_limit
  # @return [Status]
  def call(account, reblogged_status, options = {})
    reblogged_status = reblogged_status.reblog if reblogged_status.reblog?
    raise Mastodon::ValidationError, I18n.t('statuses.errors.unreleased_activity_object') if reblogged_status.ap_page?
    ExternalBridge::Guards.reject_target!(reblogged_status)

    authorize_with account, reblogged_status, :reblog?

    Reboost::Placement.new(account, reblogged_status, options).call
  end
end
