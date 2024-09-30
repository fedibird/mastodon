# frozen_string_literal: true

class Api::V1::StatusesController < Api::BaseController
  include Authorization

  before_action -> { authorize_if_got_token! :read, :'read:statuses' }, except: [:create, :destroy]
  before_action -> { doorkeeper_authorize! :write, :'write:statuses' }, only:   [:create, :destroy]
  before_action :require_user!, except:      [:index, :show, :context, :updated]
  before_action :set_statuses, only:         [:index]
  before_action :set_updated_statuses, only: [:updated]
  before_action :set_status, only:           [:show, :context]
  before_action :set_thread, only:           [:create]
  before_action :set_circle, only:           [:create]
  before_action :set_schedule, only:         [:create]
  before_action :set_expire, only:           [:create]

  override_rate_limit_headers :create, family: :statuses

  # This API was originally unlimited, pagination cannot be introduced without
  # breaking backwards-compatibility. Arbitrarily high number to cover most
  # conversations as quasi-unlimited, it would be too much work to render more
  # than this anyway
  CONTEXT_LIMIT = 4_096
  DURATION_RE = /^(?:(?<year>\d+)y)?(?:(?<month>\d+)m(?=[\do])o?)?(?:(?<day>\d+)d)?(?:(?<hour>\d+)h)?(?:(?<minute>\d+)m)?$/

  def index
    @statuses = cache_collection(@statuses, Status)
    render json: @statuses, each_serializer: REST::StatusSerializer
  end

  def show
    @status = cache_collection([@status], Status).first
    render json: @status, serializer: REST::StatusSerializer
  end

  def updated
    @statuses = cache_collection(@statuses, Status)
    render json: @statuses, each_serializer: REST::StatusSerializer
  end

  def context
    ancestors_results   = @status.in_reply_to_id.nil? ? [] : @status.ancestors(CONTEXT_LIMIT, current_account&.id)
    descendants_results = @status.descendants(CONTEXT_LIMIT, current_account&.id)
    references_results  = @status.thread_references(CONTEXT_LIMIT, current_account&.id)

    unless ActiveModel::Type::Boolean.new.cast(status_params[:with_reference])
      ancestors_results   = (ancestors_results + references_results).sort_by {|status| status.id }
      references_results  = []
    end

    loaded_ancestors    = cache_collection(ancestors_results, Status)
    loaded_descendants  = cache_collection(descendants_results, Status)
    loaded_references   = cache_collection(references_results, Status)

    @context = ::Context.new(ancestors: loaded_ancestors, descendants: loaded_descendants, references: loaded_references )
    statuses = [@status] + @context.ancestors + @context.descendants + @context.references
    accountIds = statuses.filter(&:quote?).map { |status| status.quote.account_id }.uniq

    render json: @context, serializer: REST::ContextSerializer, relationships: StatusRelationshipsPresenter.new(statuses, current_user&.account_id), account_relationships: AccountRelationshipsPresenter.new(accountIds, current_user&.account_id)
  end

  def create
    raise Mastodon::NotPermittedError if current_user.setting_disable_post

    @status = PostStatusService.new.call(current_user.account,
                                         text: status_params[:status],
                                         thread: @thread,
                                         circle: @circle,
                                         media_ids: status_params[:media_ids],
                                         sensitive: status_params[:sensitive],
                                         spoiler_text: status_params[:spoiler_text],
                                         visibility: status_params[:visibility],
                                         language: status_params[:language],
                                         scheduled_at: @scheduled_at,
                                         expires_at: @expires_at,
                                         expires_action: status_params[:expires_action],
                                         application: doorkeeper_token.application,
                                         poll: status_params[:poll],
                                         idempotency: request.headers['Idempotency-Key'],
                                         with_rate_limit: true,
                                         quote_id: status_params[:quote_id].presence,
                                         status_reference_ids: (Array(status_params[:status_reference_ids]).uniq.map(&:to_i)),
                                         status_reference_urls: status_params[:status_reference_urls] || [],
                                         searchability: status_params[:searchability]
    )
                                         

    render json: @status, serializer: @status.is_a?(ScheduledStatus) ? REST::ScheduledStatusSerializer : REST::StatusSerializer
  end

  def destroy
    @status = Status.include_expired.where(account_id: current_account.id).find(status_params[:id])
    authorize @status, :destroy?

    @status.discard
    RemovalWorker.perform_async(@status.id, redraft: true)
    @status.account.statuses_count = @status.account.statuses_count - 1

    render json: @status, serializer: REST::StatusSerializer, source_requested: true
  end

  private

  def set_statuses
    @statuses = Status.permitted_statuses_from_ids(status_ids, current_account&.id)
  end

  def set_updated_statuses
    updated_status_ids = ActiveRecord::Base.connection.select_values(ActiveRecord::Base.sanitize_sql_array([
      "select s.id from statuses s join json_to_recordset(:json) u(id bigint, updated_at timestamp without time zone) on s.id = u.id left join status_stats st on s.id = st.status_id where date_trunc('milliseconds', coalesce(st.updated_at, s.updated_at)) > date_trunc('milliseconds', u.updated_at)",
      json: Oj.dump(id_and_updated_at_pairs)]));
    @statuses = updated_status_ids.present? ? Status.permitted_statuses_from_ids(updated_status_ids, current_account&.id) : Status.none
  end

  def id_and_updated_at_pairs
    default_updated_at = updated_statuses_params[:updated_at] || Time.now.utc.iso8601
    updated_statuses_params[:d].map { |p| { updated_at: default_updated_at }.merge(p) }
  end

  def set_status
    @status = Status.include_expired.find(status_params[:id])
    authorize @status, :show?
  rescue Mastodon::NotPermittedError
    not_found
  end

  def set_thread
    @thread = status_params[:in_reply_to_id].blank? ? nil : Status.find(status_params[:in_reply_to_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: I18n.t('statuses.errors.in_reply_not_found') }, status: 404
  end

  def set_circle
    @circle = begin
      if status_params[:visibility] == 'mutual'
        status_params[:visibility] = 'limited'
        current_account
      elsif status_params[:circle_id].blank?
        nil
      else
        current_account.owned_circles.find(status_params[:circle_id])
      end
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: I18n.t('statuses.errors.circle_not_found') }, status: 404
  end

  def set_schedule
    @scheduled_at = status_params[:scheduled_at]&.to_datetime&.to_time || (status_params[:scheduled_in].blank? ? nil : Time.now.utc + status_params[:scheduled_in].to_i.seconds)
  end

  def set_expire
    expires_in =
      if status_params.has_key?(:expires_in)
        status_params[:expires_in].blank? ? nil : status_params[:expires_in].to_i.seconds
      elsif (match = current_user.setting_default_expires_in.match(DURATION_RE))
        year, month, day, hour, minute = match.to_a.values_at(1,2,3,4,5).map(&:to_i)
        seconds = (year.years + month.months + day.days + hour.hours + minute.minutes).to_i.seconds
        seconds < 1.minutes ? nil : seconds
      else
        nil
      end

    @expires_at = status_params[:expires_at] || (expires_in.nil? ? nil : (@scheduled_at || Time.now.utc) + expires_in)
  end

  def status_ids
    Array(statuses_params[:ids]).uniq.map(&:to_i)
  end

  def statuses_params
    params.permit(ids: [])
  end

  def updated_statuses_params 
    params.permit(:updated_at, d: [:id, :updated_at])
  end

  def status_params
    params.permit(
      :id,
      :status,
      :in_reply_to_id,
      :circle_id,
      :sensitive,
      :spoiler_text,
      :visibility,
      :language,
      :scheduled_in,
      :scheduled_at,
      :quote_id,
      :expires_in,
      :expires_at,
      :expires_action,
      :with_reference,
      :searchability,
      media_ids: [],
      poll: [
        :multiple,
        :hide_totals,
        :expires_in,
        options: [],
      ],
      status_reference_ids: [],
      status_reference_urls: []
    )
  end

  def pagination_params(core_params)
    params.slice(:limit).permit(:limit).merge(core_params)
  end
end
