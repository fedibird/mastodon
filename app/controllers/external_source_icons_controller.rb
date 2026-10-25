# frozen_string_literal: true

# The Fedibird-side address of a stored external feed icon (issue #569). The
# icon is a public site image shared by every subscriber of the feed, so the
# route needs no sign-in, but it is only resolvable with the stored file's
# fingerprint: a replaced icon has a new address and the old one is a 404.
# The response is a redirect to the media storage URL, so local, S3, and
# CDN-aliased storage all behave the same and the page stays same-origin.
class ExternalSourceIconsController < ApplicationController
  include RoutingHelper

  skip_before_action :store_current_location
  skip_before_action :require_functional!

  before_action :authenticate_user!, if: :whitelist_mode?
  before_action :set_icon_source

  def show
    expires_in 1.day, public: true
    redirect_to full_asset_url(@source.icon.url(:original)), status: :found
  end

  private

  def set_icon_source
    source = ExternalSource.find_by(id: params[:id])
    return not_found unless source && ExternalBridge::RSS::Icon::Delivery.stored?(source)
    return not_found unless ActiveSupport::SecurityUtils.secure_compare(source.icon_fingerprint, params[:fingerprint].to_s)

    @source = source
  end

  def not_found
    expires_in 1.minute, public: true
    head 404
  end
end
