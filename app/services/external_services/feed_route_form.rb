# frozen_string_literal: true

module ExternalServices
  # Destination choices for one User-owned external subscription. It only
  # needs the subscription revision, the saved routes, and the owner's lists,
  # so any provider that stores routes through
  # ExternalBridge::FeedRoutes::Update can render the same picker.
  class FeedRouteForm
    SUMMARY_NAME_LIMIT = 2
    SUMMARY_TITLE_LENGTH = 32

    attr_reader :revision

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

    def can_create_list?
      can_add? && @lists.length < List::PER_ACCOUNT_LIMIT
    end

    def home?
      @home
    end

    def offer_home?
      can_add? || home?
    end

    def choices
      rows = @lists.map { |id, title| { id: id, title: title, checked: @selected.include?(id) } }
      return rows if can_add?

      rows.select { |row| row[:checked] }
    end

    def selected?
      @home || selected_titles.any?
    end

    def summary
      return I18n.t('external_bridge.feed_routes.summary_none') unless selected?

      names = []
      names << I18n.t('external_bridge.feed_routes.home') if @home
      names.concat(selected_titles)
      shown = names.first(SUMMARY_NAME_LIMIT).map { |name| name.truncate(SUMMARY_TITLE_LENGTH) }
      text = shown.join(I18n.t('external_bridge.feed_routes.summary_separator'))
      hidden = names.length - shown.length
      text = I18n.t('external_bridge.feed_routes.summary_more', names: text, count: hidden) if hidden.positive?
      I18n.t('external_bridge.feed_routes.summary', destinations: text)
    end

    private

    def selected_titles
      @lists.filter_map { |id, title| title if @selected.include?(id) }
    end
  end
end
