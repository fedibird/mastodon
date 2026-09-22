# frozen_string_literal: true

class Settings::MigrationsController < Settings::BaseController
  skip_before_action :require_functional!

  before_action :require_not_suspended!
  before_action :set_migrations
  before_action :set_cooldown

  def show
    @migration = current_account.migrations.build
  end

  def create
    result = AccountMigration::CreateService.new.call(
      account: current_account,
      user: current_user,
      attributes: resource_params
    )
    @migration = result.migration

    if result.moved?
      redirect_to settings_migration_path, notice: I18n.t('migrations.moved_msg', acct: current_account.moved_to_account.acct)
    elsif result.pending_review?
      redirect_to settings_migration_path, notice: I18n.t('migrations.pending_review')
    else
      render :show
    end
  end

  helper_method :on_cooldown?

  private

  def resource_params
    params.require(:account_migration).permit(:acct, :current_password, :current_username)
  end

  def set_migrations
    @migrations = current_account.migrations.includes(:target_account).order(id: :desc).reject(&:new_record?)
    @migration_reviews = AccountMigration::ReviewLookup.for_migrations(@migrations)
  end

  def set_cooldown
    @cooldown = current_account.migrations.within_cooldown.first
  end

  def on_cooldown?
    @cooldown.present?
  end
end
