# frozen_string_literal: true

class Api::V1::Statuses::EmojiReactionsController < Api::BaseController
  include Authorization

  before_action -> { doorkeeper_authorize! :write, :'write:favourites' }
  before_action :require_user!
  before_action :set_status

  def update
    raise Mastodon::NotPermittedError if current_user.setting_disable_reactions

    if EmojiReactionService.new.call(current_account, @status, params[:id], fallback_confirmation: fallback_confirmation_param).present?
      @status = Status.include_expired.find(params[:status_id])
    end

    render json: @status, serializer: REST::StatusSerializer
  end

  def destroy
    if UnEmojiReactionService.new.call(current_account, @status, params[:id], shortcode_only: true).present?
      @status = Status.include_expired.find(params[:status_id])
    end

    render json: @status, serializer: REST::StatusSerializer, relationships: StatusRelationshipsPresenter.new([@status], current_account.id, emoji_reactions_map: { @status.id => false })
  end

  private

  def set_status
    @status = Status.include_expired.find(params[:status_id])
    authorize @status, :show?
    authorize_canonical_target!
  rescue Mastodon::NotPermittedError
    not_found
  end

  # Query string and JSON/form body both land here. A header is ignored on
  # purpose. Non-strings are no token, so a forged array cannot 500 the action.
  def fallback_confirmation_param
    value = params[:fallback_confirmation]
    value.is_a?(String) ? value : nil
  end

  # The URL status stays the subject of show?. When canonical writes are on,
  # also require show? on the status the row is stored against, so a visible
  # boost cannot be used to write a status the viewer cannot open. The
  # rendered status is still the one in the URL.
  def authorize_canonical_target!
    return unless EmojiReactionCapability::WriteConfig.canonical_writes?

    canonical = EmojiReactionCapability::WriteTarget.resolve(@status)
    return if canonical.id == @status.id

    authorize canonical, :show?
  end
end
