# frozen_string_literal: true

module ExternalServices
  # Static provider list for discovery, listing, and navigation.
  #
  # This layer must not decrypt credentials. Provider objects return
  # connection cards made from safe metadata only. A provider may return
  # zero, one, or many cards.
  class Registry
    PROVIDERS = [
      DeepL,
    ].freeze

    def self.providers
      PROVIDERS
    end

    def self.connections_for(user)
      providers.flat_map { |provider| Array(provider.connections_for(user)) }
    end

    def self.catalog_for(user)
      providers.select(&:available?).map { |provider| provider.catalog_entry_for(user) }
    end
  end
end
