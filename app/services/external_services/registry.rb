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
      RSS,
      Bluesky,
    ].freeze

    def self.providers
      PROVIDERS
    end

    def self.connections_for(user)
      providers.flat_map { |provider| Array(provider.connections_for(user)) }
    end

    def self.catalog_for(user)
      providers.select { |provider| catalog_visible?(provider, user) }.map { |provider| provider.catalog_entry_for(user) }
    end

    def self.visible_to?(provider, user)
      !provider.respond_to?(:visible_to?) || provider.visible_to?(user)
    end
    private_class_method :visible_to?

    # A permitted tester may open the explanation page when the server cannot
    # start a connection yet. Unpermitted users stay out of the catalog.
    def self.catalog_visible?(provider, user)
      return false unless visible_to?(provider, user)

      provider.available? || (provider.respond_to?(:listed_when_unconfigured?) && provider.listed_when_unconfigured?)
    end
    private_class_method :catalog_visible?
  end
end
