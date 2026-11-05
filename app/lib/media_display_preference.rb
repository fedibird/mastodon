# frozen_string_literal: true

# Saved defaults for the media timeline and account media screens.
# Unknown stored values read and write as the historical square/small pair.
module MediaDisplayPreference
  SHAPES = %w(square original).freeze
  SIZES = %w(small medium large max).freeze

  module_function

  def shape(value)
    normalized = value.to_s
    SHAPES.include?(normalized) ? normalized : 'square'
  end

  def size(value)
    normalized = value.to_s
    SIZES.include?(normalized) ? normalized : 'small'
  end
end
