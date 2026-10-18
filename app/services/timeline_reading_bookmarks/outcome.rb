# frozen_string_literal: true

module TimelineReadingBookmarks
  class Outcome
    attr_reader :bookmark, :error, :status

    def self.ok(bookmark)
      new(bookmark: bookmark)
    end

    def self.fail(error, status)
      new(error: error, status: status)
    end

    def initialize(bookmark: nil, error: nil, status: nil)
      @bookmark = bookmark
      @error = error
      @status = status
    end

    def ok?
      error.nil?
    end
  end
end
