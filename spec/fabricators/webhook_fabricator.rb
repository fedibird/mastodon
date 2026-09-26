# frozen_string_literal: true

Fabricator(:webhook) do
  url { sequence(:webhook_url) { |i| "https://example.com/hooks/#{i}" } }
  secret { SecureRandom.hex(20) }
  events { ['status.created'] }
end
