# frozen_string_literal: true

class GroupProtocol::Evidence
  def self.build(**attributes)
    {
      source: attributes[:source],
      authority: attributes[:authority],
      freshness: attributes[:freshness],
      observed_at: attributes[:observed_at],
      expires_at: attributes[:expires_at],
      uncertainty: attributes[:uncertainty],
    }
  end
end
