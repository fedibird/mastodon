# frozen_string_literal: true

class ActivityPub::GeneratorSerializer < ActiveModel::Serializer
  include RoutingHelper

  attributes :id, :type, :name, :url

  def id
    generator_url(object)
  end

  def type
    'Application'
  end

  def name
    object.name || ''
  end

  def url
    website = object.website
    # Addressable accepts characters in paths that are not valid in JSON-LD IRIs.
    return if website.blank? || website.match?(/[\u0000-\u0020\u007f<>"{}|\\^`]|%(?![0-9a-f]{2})/i)
    return unless RDF::URI.new(website).valid?

    parsed_url = Addressable::URI.parse(website)
    website if %w(http https).include?(parsed_url.normalized_scheme) && parsed_url.host.present?
  rescue Addressable::URI::InvalidURIError
    nil
  end
end

