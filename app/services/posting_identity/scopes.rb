# frozen_string_literal: true

module PostingIdentity::Scopes
  # media, reply, and quote are extra grants. Each one also requires post.
  # Existing grants do not gain reply or quote. Groups and account
  # administration are not delegable.
  ALLOWED = %w(post media reply quote).freeze

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
    return false if (list & %w(media reply quote)).any? && !list.include?('post')

    true
  end
end
