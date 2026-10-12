# frozen_string_literal: true

# Compares a Reader value with a definition. It does not change the value.
class UserPreferences::Conformance
  attr_reader :key, :mismatches

  def initialize(definition, reader_value)
    @key = definition.key
    @mismatches = mismatches_for(definition, reader_value).freeze
    freeze
  end

  def match?
    mismatches.empty?
  end

  def public_match?
    mismatches.none? { |item| item[:field] == :public_value }
  end

  def configured_match?
    mismatches.none? { |item| item[:field] == :configured }
  end

  def effective_match?
    mismatches.none? { |item| item[:field] == :effective }
  end

  def self.ruby_type(value)
    case value
    when nil then :nil
    when true, false then :boolean
    when Integer then :integer
    when String then :string
    else value.class.name.to_sym
    end
  end

  private

  def mismatches_for(definition, reader_value)
    pairs = []
    pairs << [:configured, definition.configured_type, reader_value.configured] unless definition.configured_type.nil?
    pairs << [:effective, definition.effective_type, reader_value.effective]
    pairs << [:public_value, definition.public_type, reader_value.public_value]
    pairs.filter_map do |field, expected, value|
      actual = self.class.ruby_type(value)
      next if expected.include?(actual)

      { field: field, expected: expected, actual: actual, value: value }.freeze
    end
  end
end
