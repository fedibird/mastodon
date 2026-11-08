# frozen_string_literal: true

class EmojiReferences::Invalid < ArgumentError
  attr_reader :errors

  def initialize(path, code)
    @errors = [{ path: path, code: code }]
    super("#{path}: #{code}")
  end
end
