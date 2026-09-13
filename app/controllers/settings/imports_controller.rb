# frozen_string_literal: true

class Settings::ImportsController < Settings::BaseController
  before_action :set_account

  def show
    @import = Import.new
  end

  def create
    @import = Import.new(import_params)
    @import.account = @account

    if @import.save
      enqueue_import!(@import)
      redirect_to settings_import_path, notice: I18n.t('imports.success')
    else
      render :show
    end
  end

  private

  # Route follow imports straight to their retryable processor (no extra async
  # handoff hop, and nothing destroys the import on an ambiguous enqueue failure);
  # every other import type keeps the plain, retry: false ImportWorker path.
  def enqueue_import!(import)
    if import.following?
      FollowImport::ProcessImportWorker.perform_async(import.id)
    else
      ImportWorker.perform_async(import.id)
    end
  end

  def set_account
    @account = current_user.account
  end

  def import_params
    params.require(:import).permit(:data, :type, :mode)
  end
end
