# frozen_string_literal: true

class Api::V1::Fedibird::ReadingBookmarksController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }, only: [:index, :show, :capabilities]
  before_action -> { doorkeeper_authorize! :write, :'write:statuses' }, only: [:create, :update, :destroy]
  before_action :authorize_list_write!, only: [:create, :update]
  before_action :require_user!

  def index
    rows = current_user.timeline_reading_bookmarks.order(updated_at: :desc, id: :desc)
    render json: TimelineReadingBookmarks::Presenter.new(current_user).many(rows)
  end

  def show
    render json: present(current_user.timeline_reading_bookmarks.find(params[:id]))
  end

  def create
    render_outcome(writer.create(submitted), success: 201)
  end

  def update
    render_outcome(writer.update(params[:id], submitted), success: 200)
  end

  def destroy
    current_user.timeline_reading_bookmarks.find(params[:id]).destroy!
    render_empty
  end

  def capabilities
    render json: TimelineReadingBookmarks::CapabilityMap.as_json
  end

  private

  def writer
    TimelineReadingBookmarks::Writer.new(current_user)
  end

  def present(bookmark)
    TimelineReadingBookmarks::Presenter.new(current_user).one(bookmark)
  end

  def render_outcome(outcome, success:)
    if outcome.ok?
      render json: present(outcome.bookmark), status: success
    else
      render json: { error: outcome.error }, status: outcome.status
    end
  end

  def submitted
    params.to_unsafe_h
  end

  def authorize_list_write!
    return unless list_source?

    doorkeeper_authorize! :write, :'write:lists'
  end

  def list_source?
    source = params[:source].presence || params.dig(:reading_bookmark, :source).presence
    if source.blank? && params[:id].present? && current_user
      source = current_user.timeline_reading_bookmarks.where(id: params[:id]).pick(:source)
    end
    source.to_s == 'list'
  end
end
