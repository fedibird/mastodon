# frozen_string_literal: true

module GroupCreationIcons
  # Picks a backend that is private on its own, not merely an ACL on the
  # public media bucket. An unknown or incomplete configuration raises
  # ConfigurationError. Callers must not fall back to Paperclip.
  class Storage
    def self.available?
      resolve
      true
    rescue ConfigurationError
      false
    end

    def self.resolve
      case mode
      when 'filesystem'
        Filesystem.open
      when 's3'
        S3.from_env
      when 'swift'
        Swift.from_env
      else
        raise ConfigurationError, 'private icon storage is not configured'
      end
    end

    # Explicit GROUP_CREATION_ICON_STORAGE wins. With no object store, the
    # default is a directory outside public/. S3 or Swift for public media
    # does not imply a private icon location, so uploads fail closed until
    # an operator names one.
    def self.mode
      explicit = ENV['GROUP_CREATION_ICON_STORAGE'].to_s.strip.downcase
      return explicit if explicit.present?
      return 'filesystem' unless public_object_store?

      'unavailable'
    end

    def self.public_object_store?
      ENV['S3_ENABLED'] == 'true' || ENV['SWIFT_ENABLED'] == 'true'
    end

    def self.filesystem_root
      configured = ENV['GROUP_CREATION_ICON_ROOT'].to_s.strip
      Pathname.new(configured.presence || Rails.root.join('storage', 'group_creation_icons').to_s)
    end
  end
end
