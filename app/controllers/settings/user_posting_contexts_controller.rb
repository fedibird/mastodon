# frozen_string_literal: true

class Settings::UserPostingContextsController < Settings::BaseController
  before_action :require_posting_style_access!
  before_action :set_context, only: [:edit, :update, :destroy, :duplicate]

  def index
    @contexts = current_user.user_posting_contexts.includes(:target_account).ordered
  end

  def new
    @context = current_user.user_posting_contexts.new
    @context.fill_form_fields
    load_form
  end

  def create
    @context = current_user.user_posting_contexts.new
    @context.apply_form(form_params)
    if @context.save
      redirect_to settings_user_posting_contexts_path, notice: I18n.t('user_posting_contexts.saved')
    else
      load_form
      render :new
    end
  end

  def edit
    @context.fill_form_fields
    load_form
  end

  def update
    @context.apply_form(form_params)
    if @context.save
      redirect_to settings_user_posting_contexts_path, notice: I18n.t('user_posting_contexts.saved')
    else
      load_form
      render :edit
    end
  rescue ActiveRecord::StaleObjectError
    @context.lock_version = form_params[:lock_version] if form_params.key?(:lock_version)
    @context.errors.add(:base, I18n.t('user_posting_contexts.errors.stale'))
    load_form
    render :edit, status: :conflict
  end

  def destroy
    @context.destroy!
    redirect_to settings_user_posting_contexts_path, notice: I18n.t('user_posting_contexts.deleted')
  end

  def duplicate
    copy = current_user.user_posting_contexts.new(duplicate_attributes)
    if copy.save
      redirect_to edit_settings_user_posting_context_path(copy), notice: I18n.t('user_posting_contexts.duplicated')
    else
      redirect_to settings_user_posting_contexts_path, alert: I18n.t('user_posting_contexts.errors.duplicate')
    end
  end

  def preview
    @context = preview_context
    @context.apply_form(form_params)
    @context.valid?
    load_form
    render json: {
      preview_html: render_to_string(partial: 'preview_body', formats: [:html], layout: false),
      constraint_html: render_to_string(partial: 'constraints', formats: [:html], layout: false),
      destination_html: render_to_string(partial: 'destination_conditions', formats: [:html], layout: false),
    }
  end

  private

  def require_posting_style_access!
    forbidden unless current_user&.functional? && current_user&.can?(:administrator)
  end

  def set_context
    @context = current_user.user_posting_contexts.find(params[:id])
  end

  def preview_context
    if params[:id].present?
      current_user.user_posting_contexts.find(params[:id])
    else
      current_user.user_posting_contexts.new
    end
  end

  def load_form
    @group_choices = group_choices(@context)
    @preview = UserPostingContext::Preview.build(user: current_user, context: @context)
  end

  def group_choices(context)
    ids = current_account.following.groups.limit(100).pluck(:id)
    ids += Account.local.groups.order(id: :desc).limit(50).pluck(:id)
    ids << context.target_account_id if context.target_account_id.present?
    Account.where(id: ids.uniq).order(:username, :domain)
  end

  def form_params
    params.fetch(:user_posting_context, ActionController::Parameters.new).permit(
      :name, :icon, :purpose, :target_kind, :target_account_id, :target_hashtag, :lock_version,
      :visibility_choice, :visibility_value, :language_choice, :language_code,
      :sensitive_choice, :sensitive_value, :spoiler_choice, :spoiler_text, :hashtags_text
    )
  end

  def duplicate_attributes
    {
      name: @context.name,
      icon: @context.icon,
      purpose: @context.purpose,
      target_kind: @context.target_kind,
      target_account_id: @context.target_account_id,
      target_hashtag: @context.target_hashtag,
      defaults: @context.defaults.deep_dup,
      managed: @context.managed.deep_dup,
      enabled: @context.enabled,
      schema_version: @context.schema_version,
    }
  end
end
