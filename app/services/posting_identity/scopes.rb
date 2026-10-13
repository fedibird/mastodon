# frozen_string_literal: true

module PostingIdentity::Scopes
  # media, reply, quote, and group are extra grants. Each one also
  # requires post. Existing grants do not gain group. Account
  # administration is not delegable.
  ALLOWED = %w(post media reply quote group).freeze

  module_function

  def normalize!(scopes)
    list = Array(scopes).map(&:to_s).uniq
    raise PostingIdentity::Error, :invalid_scopes unless valid?(list)

    ALLOWED.select { |scope| list.include?(scope) }
  end

  def valid?(scopes)
    list = Array(scopes).map(&:to_s).uniq
    return false if list.empty?
    return false unless (list - ALLOWED).empty?
    return false if (list & %w(media reply quote group)).any? && !list.include?('post')

    true
  end
end
