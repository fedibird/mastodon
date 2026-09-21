# frozen_string_literal: true

module Admin
  class ActionReviewSettingsController < BaseController
    def edit
      authorize :action_review_settings, :show?

      @form = Form::ActionReviewSettings.new
    end

    def update
      authorize :action_review_settings, :update?

      @form = Form::ActionReviewSettings.new(settings_params)

      if @form.save
        flash[:notice] = I18n.t('generic.changes_saved_msg')
        redirect_to edit_admin_action_review_settings_path
      else
        render :edit
      end
    end

    private

    def settings_params
      params.require(:form_action_review_settings).permit(*Form::ActionReviewSettings::OPERATIONS.map(&:to_sym))
    end
  end
end
