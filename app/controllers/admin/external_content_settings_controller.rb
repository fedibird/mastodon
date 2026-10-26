# frozen_string_literal: true

module Admin
  class ExternalContentSettingsController < BaseController
    def edit
      authorize :settings, :show?

      @form = Form::AdminExternalContentSettings.new
    end

    def update
      authorize :settings, :update?

      @form = Form::AdminExternalContentSettings.new(settings_params)
      if @form.save
        flash[:notice] = I18n.t('generic.changes_saved_msg')
        redirect_to edit_admin_external_content_settings_path
      else
        render :edit
      end
    end

    private

    def settings_params
      params.require(:form_admin_external_content_settings).permit(*Form::AdminExternalContentSettings::KEYS)
    end
  end
end
