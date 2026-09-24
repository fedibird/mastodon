# frozen_string_literal: true

class Api::V1::Peers::SearchController < Api::BaseController
  before_action :require_enabled_api!
  before_action :set_domains

  skip_before_action :require_authenticated_user!, unless: :whitelist_mode?
  skip_around_action :set_locale

  vary_by ''

  def index
    cache_even_if_authenticated!
    render json: @domains
  end

  private

  def require_enabled_api!
    head 404 unless Setting.peers_api_enabled && !whitelist_mode?
  end

  def set_domains
    return if params[:q].blank?

    if Chewy.enabled?
      @domains = InstancesIndex.query(function_score: {
        query: {
          prefix: {
            domain: TagManager.instance.normalize_domain(params[:q].strip),
          },
        },

        field_value_factor: {
          field: 'accounts_count',
          modifier: 'log2p',
        },
      }).limit(10).pluck(:domain)
    else
      domain = params[:q].strip
      domain = TagManager.instance.normalize_domain(domain)
      @domains = Instance.searchable.where(Instance.arel_table[:domain].matches("#{Instance.sanitize_sql_like(domain)}%", false, true)).limit(10).pluck(:domain)
    end
  rescue Addressable::URI::InvalidURIError
    @domains = []
  end

  # Same cache window as Mastodon 4.2 ApiCachingConcern, using Fedibird's whitelist mode.
  def cache_even_if_authenticated!
    expires_in(5.minutes, public: true, stale_while_revalidate: 30.seconds, stale_if_error: 1.day) unless whitelist_mode?
  end
end
