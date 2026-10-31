# frozen_string_literal: true

class Settings::Preferences::ComposerController < Settings::BaseController
  before_action :assign_toolbar, only: :show

  def show; end

  def update
    raw = composer_toolbar_param
    ComposerToolbarPreference.write!(current_user, raw)
    redirect_to settings_preferences_composer_path, notice: I18n.t('generic.changes_saved_msg')
  rescue ComposerToolbarPreference::Invalid, ActionController::ParameterMissing
    current_user.errors.add(:base, I18n.t('preferences.invalid_input', key: I18n.t('composer_toolbar.title')))
    @saved_toolbar = ComposerToolbarPreference.effective(current_user)
    submitted = params.dig(:user, :composer_toolbar)
    @toolbar = ComposerToolbarPreference.normalize(submitted)
    render :show, status: :unprocessable_entity
  end

  private

  def assign_toolbar
    @saved_toolbar = ComposerToolbarPreference.effective(current_user)
    @toolbar = @saved_toolbar
  end

  def composer_toolbar_param
    params.require(:user).permit(:composer_toolbar)[:composer_toolbar]
  end
end
