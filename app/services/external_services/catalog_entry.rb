# frozen_string_literal: true

module ExternalServices
  # One Add service row. The path always opens that provider's own page.
  class CatalogEntry
    attr_reader :provider_key, :title, :description, :icon, :status, :status_label, :action, :path

    def initialize(attributes)
      @provider_key = attributes.fetch(:provider_key)
      @title = attributes.fetch(:title)
      @description = attributes.fetch(:description)
      @icon = attributes.fetch(:icon)
      @status = attributes[:status]
      @status_label = attributes[:status_label]
      @action = attributes.fetch(:action)
      @path = attributes.fetch(:path)
    end

    def configured?
      !status.nil?
    end
  end
end
