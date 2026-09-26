# frozen_string_literal: true

require 'rails_helper'

module MastodonVersionEnv
  def with_version_env(prerelease, metadata)
    original_prerelease = ENV.fetch('MASTODON_VERSION_PRERELEASE', nil)
    original_metadata = ENV.fetch('MASTODON_VERSION_METADATA', nil)
    assign_env('MASTODON_VERSION_PRERELEASE', prerelease)
    assign_env('MASTODON_VERSION_METADATA', metadata)
    described_class.instance_variable_set(:@gem_version, nil)

    yield
  ensure
    restore_env('MASTODON_VERSION_PRERELEASE', original_prerelease)
    restore_env('MASTODON_VERSION_METADATA', original_metadata)
    described_class.instance_variable_set(:@gem_version, nil)
    described_class.instance_variable_set(:@user_agent, nil)
  end

  def assign_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  def restore_env(key, value)
    assign_env(key, value)
  end
end

describe Mastodon::Version do
  include MastodonVersionEnv

  describe '.to_s' do
    it 'advertises Mastodon 4.2.13' do
      with_version_env(nil, nil) do
        expect(described_class.to_s).to eq '4.2.13'
      end
    end

    it 'appends a prerelease from the environment' do
      with_version_env('beta.1', nil) do
        expect(described_class.to_s).to eq '4.2.13-beta.1'
      end
    end

    it 'appends build metadata from the environment' do
      with_version_env(nil, 'custom') do
        expect(described_class.to_s).to eq '4.2.13+custom'
      end
    end

    it 'combines a prerelease and build metadata' do
      with_version_env('beta.1', 'custom') do
        expect(described_class.to_s).to eq '4.2.13-beta.1+custom'
      end
    end
  end

  describe '.user_agent' do
    it 'includes the Mastodon compatibility version and the Fedibird identifier' do
      described_class.instance_variable_set(:@user_agent, nil)

      with_version_env(nil, nil) do
        user_agent = described_class.user_agent

        expect(user_agent).to include('Mastodon/4.2.13')
        expect(user_agent).to include('Fedibird/0.1')
      end
    end
  end

  describe '.repository' do
    it 'keeps the Fedibird source repository' do
      original_repository = ENV.fetch('GITHUB_REPOSITORY', nil)
      original_source_base_url = ENV.fetch('SOURCE_BASE_URL', nil)
      original_source_tag = ENV.fetch('SOURCE_TAG', nil)
      ENV.delete('GITHUB_REPOSITORY')
      ENV.delete('SOURCE_BASE_URL')
      ENV.delete('SOURCE_TAG')

      expect(described_class.repository).to eq 'fedibird/mastodon'
      expect(described_class.source_url).to eq 'https://github.com/fedibird/mastodon'
    ensure
      restore_env('GITHUB_REPOSITORY', original_repository)
      restore_env('SOURCE_BASE_URL', original_source_base_url)
      restore_env('SOURCE_TAG', original_source_tag)
    end
  end
end
