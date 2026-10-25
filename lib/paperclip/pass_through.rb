# frozen_string_literal: true

module Paperclip
  # Keeps an already vetted file exactly as uploaded. It never runs
  # ImageMagick on it, so a format the caller has validated itself (a favicon
  # ICO) does not depend on, or widen, ImageMagick's coder policy.
  class PassThrough < Paperclip::Processor
    def make
      File.open(@file.path)
    end
  end
end
