# frozen_string_literal: true

class Api::V1::ReportsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :write, :'write:reports' }, only: [:create]
  before_action :require_user!

  override_rate_limit_headers :create, family: :reports

  def create
    raise Mastodon::NotPermittedError if current_user.setting_disable_report

    @report = ReportService.new.call(
      current_account,
      reported_account,
      status_ids: reported_status_ids,
      comment: report_params[:comment],
      category: report_params[:category],
      rule_ids: report_params[:rule_ids],
      forward: report_params[:forward],
      forward_to_domains: report_params[:forward_to_domains]
    )

    render json: @report, serializer: REST::ReportSerializer
  end

  private

  def reported_status_ids
    reported_account.statuses.with_discarded.permitted_for(reported_account, current_account).find(status_ids).pluck(:id)
  end

  def status_ids
    Array(report_params[:status_ids])
  end

  def reported_account
    Account.find(report_params[:account_id])
  end

  def report_params
    params.permit(:account_id, :comment, :category, :forward, forward_to_domains: [], status_ids: [], rule_ids: [])
  end
end
