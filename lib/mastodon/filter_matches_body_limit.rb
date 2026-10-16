# frozen_string_literal: true

require 'stringio'

module Mastodon
  # Bound reads before Rails parses/logs JSON, including chunked requests.
  class FilterMatchesBodyLimit
    PATH = '/api/v1/fedibird/filters/matches'
    PATH_PATTERN = /\A#{Regexp.escape(PATH)}(?:\.[^\/]+)?\/?\z/
    LIMIT = 8_192

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless env['REQUEST_METHOD'] == 'POST'

      path = Rack::Utils.unescape_path(env['PATH_INFO']).gsub(%r{/+}, '/')
      return @app.call(env) unless PATH_PATTERN.match?(path)

      return too_large if env['CONTENT_LENGTH'].to_i > LIMIT

      body = env['rack.input'].read(LIMIT + 1) || ''
      return too_large if body.bytesize > LIMIT

      env['rack.input'] = StringIO.new(body)
      @app.call(env)
    end

    private

    def too_large
      [413, { 'Content-Type' => 'application/json', 'Cache-Control' => 'private, no-store' }, ['{"error":"Request body exceeds 8192 bytes"}']]
    end
  end
end
