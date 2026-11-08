# frozen_string_literal: true

module EmojiMutes
  class Store < ActiveSupport::CurrentAttributes
    attribute :rule_sets, :breakdowns, :breakdown_loads
  end
end
