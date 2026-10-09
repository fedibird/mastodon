# frozen_string_literal: true

module PostingIdentity::Scopes
  # media is an extra grant. Editing, replies, groups, and account
  # administration are not delegable in this stage.
  ALLOWED = %w(post media).freeze

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
    return false if list.include?('media') && !list.include?('post')

    true
  end
end
