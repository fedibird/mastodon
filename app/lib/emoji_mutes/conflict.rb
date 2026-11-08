# frozen_string_literal: true

class EmojiMutes::Conflict < StandardError
  attr_reader :path, :code

  def initialize(message, path:, code:)
    @path = path
    @code = code
    super(message)
  end
end
