# frozen_string_literal: true

class Api::V1::Instances::ExtendedDescriptionsController < Api::BaseController
  skip_before_action :require_authenticated_user!, unless: :whitelist_mode?
  skip_around_action :set_locale

  before_action :set_extended_description

  vary_by ''

  def show
    render json: @extended_description, serializer: REST::ExtendedDescriptionSerializer
  end

  private

  def set_extended_description
    @extended_description = ExtendedDescription.current
  end
end
