# frozen_string_literal: true

module ExternalServices
  # One Add service row. The path always opens that provider's own page.
  #
  # configured? is whether a connection already exists. status is only the
  # presentation state, so an unavailable vault with no row is not configured.
  class CatalogEntry
    ACTIONS = %i(add manage).freeze

    attr_reader :provider_key, :title, :description, :icon, :status, :status_label, :action, :path

    def initialize(attributes)
      @provider_key = attributes.fetch(:provider_key)
      @title = attributes.fetch(:title)
      @description = attributes.fetch(:description)
      @icon = attributes.fetch(:icon)
      @configured = attributes.fetch(:configured)
      @status = attributes[:status]
      @status_label = attributes[:status_label]
      @action = attributes.fetch(:action)
      @path = attributes.fetch(:path)

      raise ArgumentError, 'configured must be boolean' unless @configured == true || @configured == false
      raise ArgumentError, 'unknown catalog action' unless ACTIONS.include?(@action)
      raise ArgumentError, 'unknown catalog status' if @status && !Connection::IMPLEMENTED_STATUSES.include?(@status)
    end

    def configured?
      @configured
    end
  end
end
