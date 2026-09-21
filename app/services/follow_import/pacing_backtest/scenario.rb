# frozen_string_literal: true

require 'json'

# Operator-supplied candidate profiles. Numbers are never bundled as
# production defaults; every scenario is validated through the existing
# RemoteAdmission / AdaptiveRemote parsers.
module FollowImport
  class PacingBacktest
    class Scenario
      Candidate = Struct.new(
        :name,
        :global_budget,
        :fixed_profile,
        :adaptive_profile,
        :raw,
        keyword_init: true
      ) do
        def adaptive?
          !adaptive_profile.nil?
        end
      end

      attr_reader :schema_version, :bucket_seconds, :candidates

      def self.load(path)
        new(path)
      end

      def initialize(path)
        raise FollowImport::PacingBacktest::Error, 'missing required input file (SCENARIOS)' if path.to_s.strip.empty?
        raise FollowImport::PacingBacktest::Error, "missing required input file (SCENARIOS): #{path}" unless File.file?(path)

        payload = parse_json(path)
        @schema_version = payload['schema_version']
        unless @schema_version == FollowImport::PacingBacktest::SCENARIO_SCHEMA_VERSION
          raise FollowImport::PacingBacktest::Error, "invalid scenario schema_version (expected #{FollowImport::PacingBacktest::SCENARIO_SCHEMA_VERSION})"
        end

        @bucket_seconds = require_positive_int(payload['bucket_seconds'], 'bucket_seconds')
        list = payload['scenarios']
        unless list.is_a?(Array) && list.any?
          raise FollowImport::PacingBacktest::Error, 'scenarios must be a non-empty array'
        end

        unknown = payload.keys.map(&:to_s) - %w(schema_version bucket_seconds scenarios)
        raise FollowImport::PacingBacktest::Error, "unknown scenario-file keys: #{unknown.join(', ')}" if unknown.any?

        @candidates = list.map { |entry| build_candidate(entry) }
      end

      private

      def parse_json(path)
        data = JSON.parse(File.read(path))
        raise FollowImport::PacingBacktest::Error, 'invalid scenario schema: root must be an object' unless data.is_a?(Hash)

        data
      rescue JSON::ParserError => e
        raise FollowImport::PacingBacktest::Error, "invalid scenario schema: #{e.message}"
      end

      def build_candidate(entry)
        unless entry.is_a?(Hash)
          raise FollowImport::PacingBacktest::Error, 'invalid scenario schema: scenario must be an object'
        end

        data = entry.transform_keys(&:to_s)
        name = data['name'].to_s.strip
        raise FollowImport::PacingBacktest::Error, 'invalid scenario schema: name is required' if name.empty?

        unknown = data.keys - %w(name global_budget fixed_profile adaptive_profile)
        raise FollowImport::PacingBacktest::Error, "unknown scenario keys for #{name}: #{unknown.join(', ')}" if unknown.any?

        fixed = parse_fixed(data['fixed_profile'], name)
        adaptive = parse_adaptive(data['adaptive_profile'], name, fixed)
        Candidate.new(
          name: name,
          global_budget: parse_optional_budget(data['global_budget'], name),
          fixed_profile: fixed,
          adaptive_profile: adaptive,
          raw: data
        )
      end

      def parse_fixed(raw, name)
        profile = FollowImport::RemoteAdmissionProfile.parse(raw)
        if profile.invalid?
          raise FollowImport::PacingBacktest::Error, "invalid fixed profile for #{name}: #{profile.error}"
        end
        unless profile.configured?
          raise FollowImport::PacingBacktest::Error, "invalid fixed profile for #{name}: profile is required"
        end

        profile
      end

      def parse_adaptive(raw, name, fixed)
        return if raw.nil?

        profile = FollowImport::AdaptiveRemoteProfile.parse(raw)
        if profile.invalid?
          raise FollowImport::PacingBacktest::Error, "invalid adaptive profile for #{name}: #{profile.error}"
        end
        unless profile.configured?
          raise FollowImport::PacingBacktest::Error, "invalid adaptive profile for #{name}: adaptive profile is unconfigured"
        end

        check = FollowImport::AdaptiveRemoteCompatibility.check(profile, fixed)
        unless check.ok
          raise FollowImport::PacingBacktest::Error, "incompatible adaptive profile for #{name}: #{check.error}"
        end

        profile
      end

      def parse_optional_budget(value, name)
        return if value.nil?

        require_positive_int(value, "#{name}.global_budget")
      end

      def require_positive_int(value, label)
        unless value.is_a?(Numeric) && value == value.to_i && value.to_i.positive?
          raise FollowImport::PacingBacktest::Error, "invalid scenario schema: #{label} must be an integer > 0"
        end

        value.to_i
      end
    end
  end
end
