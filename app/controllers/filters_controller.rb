# frozen_string_literal: true

class FiltersController < ApplicationController
  include EmbeddedFilterSettings

  before_action :authenticate_user!
  before_action :set_filter, only: [:edit, :update, :destroy]
  before_action :set_cache_headers
  before_action :set_body_classes

  def index
    @filters = current_account.custom_filters.includes(:keywords, :statuses).order(:phrase)
  end

  def new
    @filter = current_account.custom_filters.build(action: :warn, context: CustomFilter::VALID_CONTEXTS.dup)
    @filter.keywords.build
  end

  def edit; end

  def create
    @filter = current_account.custom_filters.build(resource_params)

    if @filter.save
      redirect_to filters_path(embedded_filter_options)
    else
      render :new
    end
  end

  def update
    if @filter.update(resource_params)
      redirect_to filters_path(embedded_filter_options)
    else
      render :edit
    end
  end

  def destroy
    @filter.destroy
    redirect_to filters_path(embedded_filter_options)
  end

  private

  def set_filter
    @filter = current_account.custom_filters.find(params[:id])
  end

  def resource_params
    params.require(:custom_filter).permit(:title, :expires_in, :filter_action, context: [], keywords_attributes: [:id, :keyword, :whole_word, :_destroy])
  end

  def set_cache_headers
    response.cache_control.replace(private: true, no_store: true)
  end

  def set_body_classes
    @body_classes = 'admin'
  end
end
