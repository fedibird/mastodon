# frozen_string_literal: true

Fabricator(:preview_card) do
  url { Faker::Internet.unique.url }
  title 'Preview'
  description 'A preview card'
  provider_name 'Example'
  type :link
end
