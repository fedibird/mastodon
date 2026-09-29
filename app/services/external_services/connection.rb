# frozen_string_literal: true

module ExternalServices
  # Safe card fields for one connection. This object has no secret payload.
  class Connection
    IMPLEMENTED_STATUSES = %i(connected warning unavailable).freeze

    attr_reader :provider_key, :title, :subtitle, :status, :status_label,
                :last_used_at, :manage_path, :icon

    def initialize(attributes)
      @provider_key = attributes.fetch(:provider_key)
      @title = attributes.fetch(:title)
      @subtitle = attributes.fetch(:subtitle)
      @status = attributes.fetch(:status)
      @status_label = attributes.fetch(:status_label)
      @last_used_at = attributes[:last_used_at]
      @manage_path = attributes.fetch(:manage_path)
      @icon = attributes.fetch(:icon)

      raise ArgumentError, 'unknown connection status' unless IMPLEMENTED_STATUSES.include?(@status)
    end
  end
end
