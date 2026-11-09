# frozen_string_literal: true

module EmojiMutes
  class Conflict < StandardError
    attr_reader :code

    def initialize(code = 'conflict')
      @code = code
      super('Emoji mute conflict')
    end
  end
end
