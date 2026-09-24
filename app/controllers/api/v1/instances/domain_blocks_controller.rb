# frozen_string_literal: true

class Api::V1::Instances::DomainBlocksController < Api::BaseController
  skip_before_action :require_authenticated_user!, unless: :whitelist_mode?

  vary_by '', if: -> { domain_blocks_response_shared? }

  before_action :require_enabled_api!
  before_action :set_domain_blocks

  def index
    if domain_blocks_response_shared?
      cache_even_if_authenticated!
    else
      cache_if_unauthenticated!
    end

    render json: @domain_blocks,
           each_serializer: REST::DomainBlockSerializer,
           with_comment: show_rationale?
  end

  private

  def require_enabled_api!
    head 404 unless domain_blocks_shown?
  end

  def set_domain_blocks
    @domain_blocks = DomainBlock.where(severity: [:silence, :suspend]).by_severity
  end

  def domain_blocks_response_shared?
    Setting.show_domain_blocks == 'all' &&
      Setting.show_domain_blocks_rationale != 'users'
  end

  def domain_blocks_shown?
    Setting.show_domain_blocks == 'all' || (Setting.show_domain_blocks == 'users' && current_user_can_view_domain_blocks?)
  end

  def show_rationale?
    Setting.show_domain_blocks_rationale == 'all' || (Setting.show_domain_blocks_rationale == 'users' && current_user_can_view_domain_blocks?)
  end

  def current_user_can_view_domain_blocks?
    user = current_user
    return false if user.nil?
    return true if user.functional?

    user.confirmed? &&
      user.approved? &&
      !user.disabled? &&
      !user.account.suspended? &&
      !user.account.memorial? &&
      user.account.moved?
  end
end
