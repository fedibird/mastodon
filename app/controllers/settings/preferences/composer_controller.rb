# frozen_string_literal: true

class Settings::Preferences::ComposerController < Settings::BaseController
  before_action :assign_toolbar, only: :show

  def show; end

  def update
    ComposerToolbarPreference.write!(current_user, composer_toolbar_param)
    redirect_to settings_preferences_composer_path, notice: I18n.t('generic.changes_saved_msg')
  rescue ComposerToolbarPreference::Invalid, ActionController::ParameterMissing
    current_user.errors.add(:base, I18n.t('preferences.invalid_input', key: I18n.t('composer_toolbar.title')))
    assign_toolbar
    render :show, status: :unprocessable_entity
  end

  private

  def assign_toolbar
    @toolbar = ComposerToolbarPreference.effective(current_user)
  end

  def composer_toolbar_param
    params.require(:user).permit(:composer_toolbar)[:composer_toolbar]
  end
end
