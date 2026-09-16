# frozen_string_literal: true

# Compatibility between a parsed AdaptiveRemoteProfile and the PR F
# fixed RemoteAdmissionProfile that remains the hard safety ceiling.
#
# Kept separate from AdaptiveRemoteProfile so the standalone parser can
# stay valid without a configured fixed baseline. A valid adaptive
# profile that exceeds the corresponding fixed cap is not activated.
module FollowImport
  class AdaptiveRemoteCompatibility
    Result = Struct.new(:ok, :error, keyword_init: true)

    def self.check(adaptive_profile, fixed_profile)
      return Result.new(ok: false, error: 'adaptive profile is not configured') unless adaptive_profile&.configured?
      return Result.new(ok: false, error: 'fixed baseline profile is not configured') unless fixed_profile&.configured?

      errors = []
      compare(errors, 'destination.initial_cap', adaptive_profile.destination.initial_cap, fixed_profile.destination_per_tick_cap)
      compare(errors, 'destination.min_cap', adaptive_profile.destination.min_cap, fixed_profile.destination_per_tick_cap)
      compare(errors, 'origin.initial_cap', adaptive_profile.origin.initial_cap, fixed_profile.origin_per_tick_cap)
      compare(errors, 'origin.min_cap', adaptive_profile.origin.min_cap, fixed_profile.origin_per_tick_cap)

      Result.new(ok: errors.empty?, error: errors.join('; ').presence)
    end

    def self.compatible?(adaptive_profile, fixed_profile)
      check(adaptive_profile, fixed_profile).ok
    end

    def self.compare(errors, label, adaptive_value, fixed_value)
      return if adaptive_value.to_i <= fixed_value.to_i

      errors << "#{label} must be <= corresponding fixed cap (#{fixed_value})"
    end
    private_class_method :compare
  end
end
