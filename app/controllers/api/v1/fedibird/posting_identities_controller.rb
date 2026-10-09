# frozen_string_literal: true

class Api::V1::Fedibird::PostingIdentitiesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:accounts' }
  before_action :require_user!
  before_action :require_administrator!

  def index
    render json: PostingIdentity::Catalog.new(current_user), serializer: REST::PostingIdentityCatalogSerializer
  end

  private

  def require_administrator!
    raise Mastodon::NotPermittedError unless current_user.can?(:administrator)
  end
end
