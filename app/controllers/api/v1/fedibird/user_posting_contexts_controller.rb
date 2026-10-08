# frozen_string_literal: true

class Api::V1::Fedibird::UserPostingContextsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }
  before_action :require_user!
  before_action :require_owner!

  def index
    render json: enabled_styles.map(&:composer_api_payload)
  end

  private

  def enabled_styles
    current_user.user_posting_contexts.enabled.ordered.includes(:target_account)
  end

  def require_owner!
    raise Mastodon::NotPermittedError unless current_user.can?(:administrator)
  end
end
