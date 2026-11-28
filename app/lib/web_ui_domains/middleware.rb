# frozen_string_literal: true

module WebUiDomains
  # Records the request context and always continues.
  #
  # P1 does not insert this middleware. When a later phase does, it belongs
  # immediately before ActionDispatch::Cookies, which is before the cookie
  # session store. It must not rewrite config, default_url_options, or the
  # session cookie key. The gate passed here is always closed.
  class Middleware
    CONTEXT_KEY = 'web_ui_domains.context'

    def initialize(app)
      @app = app
    end

    def call(env)
      env[CONTEXT_KEY] = RequestContext.build(ActionDispatch::Request.new(env))
      @app.call(env)
    end
  end
end
