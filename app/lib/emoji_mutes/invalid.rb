# frozen_string_literal: true

module EmojiMutes
  class Invalid < StandardError
    attr_reader :errors

    def initialize(path, code)
      @errors = [{ 'path' => path, 'code' => code }]
      super('Invalid emoji mute')
    end
  end
end
