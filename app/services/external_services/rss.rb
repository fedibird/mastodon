# frozen_string_literal: true

module ExternalServices
  # Public RSS/Atom subscriptions. No credential is read or stored.
  module RSS
    KEY = 'rss'
    ICON = 'external_services/rss.svg'
    LIST_LIMIT = 50

    class Summary
      attr_reader :total, :active, :paused, :errored, :attention, :checked_at

      def initialize(attributes)
        @total = attributes.fetch(:total)
        @active = attributes.fetch(:active)
        @paused = attributes.fetch(:paused)
        @errored = attributes.fetch(:errored)
        @attention = attributes.fetch(:attention)
        @checked_at = attributes[:checked_at]
      end

      def self.empty
        new({ total: 0, active: 0, paused: 0, errored: 0, attention: 0, checked_at: nil })
      end
    end

    class Page
      attr_reader :subscriptions, :items, :enabled, :permitted, :page, :total_count, :total_pages

      def initialize(attributes)
        @subscriptions = attributes.fetch(:subscriptions)
        @items = attributes.fetch(:items)
        @enabled = attributes.fetch(:enabled)
        @permitted = attributes.fetch(:permitted)
        @page = attributes.fetch(:page)
        @total_count = attributes.fetch(:total_count)
        @total_pages = attributes.fetch(:total_pages)
      end

      def show_form?
        permitted
      end

      def blocked_reason
        return I18n.t('external_bridge.disabled') unless enabled
        return I18n.t('external_bridge.tester_only') unless permitted

        nil
      end
    end

    # Safe fields for one owned subscription. Titles and URLs stay untrusted.
    class SubscriptionRow
      def initialize(subscription)
        @subscription = subscription
        @source = subscription.external_source
      end

      def id
        @subscription.id
      end

      def title
        @source.title.presence || I18n.t('external_bridge.untitled')
      end

      def url
        @source.canonical_key.to_s
      end

      def linkable_url
        url if url.match?(%r{\Ahttps?://}i)
      end

      def state
        @subscription.state
      end

      def state_label
        case state
        when 'active' then I18n.t('external_bridge.state.active')
        when 'paused' then I18n.t('external_bridge.state.paused')
        else I18n.t('external_bridge.state.error')
        end
      end

      def badge
        case state
        when 'active' then 'connected'
        when 'paused' then 'warning'
        else 'unavailable'
        end
      end

      def checked_at
        @subscription.checked_at
      end

      def fetch_error_message
        code = @subscription.last_error_code
        return if code.blank?

        I18n.t("external_bridge.errors.#{code}", default: I18n.t('external_bridge.errors.fetch_failed'))
      end

      def partial_failure_message
        count = @subscription.failed_item_count.to_i
        return if count <= 0

        I18n.t('external_bridge.partial_item_failure', count: count)
      end

      def retry_message
        return unless state == 'error'

        count = @subscription.retry_count.to_i
        return if @subscription.next_retry_at.blank? && count <= 0

        if @subscription.next_retry_at.present?
          I18n.t('external_bridge.retry_status', time: I18n.l(@subscription.next_retry_at), count: count)
        else
          I18n.t('external_bridge.retry_status_unscheduled', count: count)
        end
      end

      def pausable?
        state == 'active'
      end

      def resumable?
        state != 'active'
      end

      def route_form
        @route_form
      end

      def route_form=(value)
        @route_form = value
      end
    end

    # Choices for one subscription. Built from rows already loaded for the
    # page so the settings list does not query once per feed.
    class RouteForm
      def initialize(subscription, routes:, lists:, feeds_permitted:)
        @revision = subscription.feed_routes_revision.to_i
        @home = routes.fetch(:home, false)
        @selected = routes.fetch(:list_ids, [])
        @lists = lists
        @feeds_permitted = feeds_permitted
      end

      def show?
        @feeds_permitted || @home || @selected.any?
      end

      def can_add?
        @feeds_permitted
      end

      def home?
        @home
      end

      def offer_home?
        can_add? || home?
      end

      def revision
        @revision
      end

      def choices
        rows = @lists.map { |id, title| { id: id, title: title, checked: @selected.include?(id) } }
        return rows if can_add?

        rows.select { |row| row[:checked] }
      end
    end

    class << self
      def key
        KEY
      end

      def display_name
        I18n.t('external_services.providers.rss.name')
      end

      def icon
        ICON
      end

      def description
        I18n.t('external_services.providers.rss.description')
      end

      def available?
        ExternalBridge::Feature.enabled?
      end

      def visible_to?(user)
        ExternalBridge::Feature.permitted?(user)
      end

      def manage_path
        routes.settings_external_services_rss_path
      end

      def connections_for(user)
        summary = summary_for(user)
        return [] if summary.total.zero?

        status = hub_status(summary, user)
        [card_for(summary, status)]
      end

      def catalog_entry_for(user)
        summary = summary_for(user)
        configured = summary.total.positive?
        status = hub_status(summary, user) if configured
        CatalogEntry.new(
          provider_key: key,
          title: display_name,
          description: description,
          detail: (count_label(summary) if configured),
          icon: icon,
          configured: configured,
          status: status,
          status_label: (hub_status_label(status, summary) if status),
          action: configured ? :manage : :add,
          action_label: configured ? I18n.t('external_services.actions.rss.manage') : I18n.t('external_services.actions.rss.add'),
          path: manage_path
        )
      end

      def page_for(user, page: 1)
        summary = summary_for(user)
        number = clamp_page(page, summary.total)
        rows = subscription_scope(user).includes(:external_source).order(id: :desc).offset((number - 1) * LIST_LIMIT).limit(LIST_LIMIT).to_a
        forms = route_forms_for(user, rows)
        attributes = {
          subscriptions: rows.map { |row| SubscriptionRow.new(row).tap { |item| item.route_form = forms[row.id] } },
          items: items_for(user),
          enabled: available?,
          permitted: ExternalBridge::Feature.permitted?(user),
          page: number,
          total_count: summary.total,
          total_pages: page_count(summary.total),
        }
        Page.new(attributes)
      end

      private

      def card_for(summary, status)
        Connection.new(
          provider_key: key,
          title: display_name,
          lead: description,
          subtitle: count_label(summary),
          status: status,
          status_label: hub_status_label(status, summary),
          last_used_at: summary.checked_at,
          shows_check_time: true,
          manage_label: I18n.t('external_services.actions.rss.manage'),
          manage_path: manage_path,
          icon: icon
        )
      end

      def summary_for(user)
        return Summary.empty if user.nil?

        total, active, paused, errored, attention, checked_at = subscription_scope(user).pick(
          Arel.sql('COUNT(*)'),
          Arel.sql("COUNT(*) FILTER (WHERE state = 'active')"),
          Arel.sql("COUNT(*) FILTER (WHERE state = 'paused')"),
          Arel.sql("COUNT(*) FILTER (WHERE state = 'error')"),
          Arel.sql("COUNT(*) FILTER (WHERE state = 'error' OR failed_item_count > 0 OR (last_error_code IS NOT NULL AND last_error_code <> ''))"),
          Arel.sql('MAX(checked_at)')
        )
        summary = {
          total: total.to_i,
          active: active.to_i,
          paused: paused.to_i,
          errored: errored.to_i,
          attention: attention.to_i,
          checked_at: coerce_time(checked_at),
        }
        Summary.new(summary)
      end

      def hub_status(summary, user)
        return :warning if summary.attention.positive?
        return :unavailable unless ExternalBridge::Feature.permitted?(user)
        return :warning if summary.active.zero? && summary.paused.positive?

        :connected
      end

      def hub_status_label(status, summary)
        if status == :warning && summary.attention.zero? && summary.active.zero? && summary.paused.positive?
          I18n.t('external_bridge.state.paused')
        else
          I18n.t("external_services.status.#{status}")
        end
      end

      def count_label(summary)
        I18n.t(
          'external_services.providers.rss.subtitle',
          count: summary.total,
          active: summary.active,
          paused: summary.paused,
          error: summary.errored
        )
      end

      def items_for(user)
        return [] if user.nil?

        ExternalStatusProjection.where(user_id: user.id)
                                .includes(:status, external_resource: :external_source)
                                .order(id: :desc)
                                .limit(40)
                                .to_a
      end

      def route_forms_for(user, rows)
        return {} if user.nil? || rows.empty?

        grouped = Hash.new { |hash, key| hash[key] = { home: false, list_ids: [] } }
        route_rows = ExternalFeedRoute.where(user_id: user.id, external_subscription_id: rows.map(&:id)).to_a
        route_rows.each do |route|
          bucket = grouped[route.external_subscription_id]
          if route.destination == 'home'
            bucket[:home] = true
          else
            bucket[:list_ids] << route.list_id
          end
        end
        permitted = ExternalBridge::Feeds::Feature.permitted?(user)
        lists = if permitted || route_rows.any?
                  List.where(account_id: user.account_id).order(:id).limit(List::PER_ACCOUNT_LIMIT).pluck(:id, :title)
                else
                  []
                end
        rows.each_with_object({}) do |row, memo|
          memo[row.id] = RouteForm.new(row, routes: grouped[row.id], lists: lists, feeds_permitted: permitted)
        end
      end

      def subscription_scope(user)
        return ExternalSubscription.none if user.nil?

        ExternalSubscription.where(user_id: user.id)
      end

      def clamp_page(page, total)
        number = page.to_i
        number = 1 if number < 1
        number = 10_000 if number > 10_000
        pages = page_count(total)
        return 1 if pages.zero?
        return pages if number > pages

        number
      end

      def page_count(total)
        return 0 if total.zero?

        (total.to_f / LIST_LIMIT).ceil
      end

      def coerce_time(value)
        case value
        when nil then nil
        when Time, ActiveSupport::TimeWithZone then value
        else Time.zone.parse(value.to_s)
        end
      end

      def routes
        Rails.application.routes.url_helpers
      end
    end
  end
end
