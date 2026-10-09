# frozen_string_literal: true

class PostingIdentity::Error < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
    super(code.to_s)
  end
end
