# frozen_string_literal: true

module ApiCachingConcern
  extend ActiveSupport::Concern

  def cache_if_unauthenticated!
    return if user_signed_in?

    apply_public_cache(15.seconds)
  end

  def cache_even_if_authenticated!
    return if whitelist_mode?

    apply_public_cache(5.minutes)
  end

  private

  def apply_public_cache(max_age)
    expires_in(max_age, public: true, stale_while_revalidate: 30.seconds, stale_if_error: 1.day)
    response.headers['Cache-Control'] = "max-age=#{max_age.to_i}, public, stale-while-revalidate=30, stale-if-error=86400"
  end
end
