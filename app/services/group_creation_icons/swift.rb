# frozen_string_literal: true

module GroupCreationIcons
  # A dedicated Swift container. The public media container is refused.
  # Objects are created with public: false and are never given a temp URL.
  class Swift
    def self.from_env
      container = ENV['GROUP_CREATION_ICON_SWIFT_CONTAINER'].to_s.strip
      public_container = ENV['SWIFT_CONTAINER'].to_s.strip
      validate_container!(container, public_container)
      raise ConfigurationError, 'refusing a public icon container' if ActiveModel::Type::Boolean.new.cast(ENV['GROUP_CREATION_ICON_SWIFT_PUBLIC'])

      new(container: container, public_container: public_container, directories: build_directories)
    end

    def self.validate_container!(container, public_container)
      raise ConfigurationError, 'missing private icon container' if container.blank?
      raise ConfigurationError, 'invalid private icon container' if container.include?('/') || container.include?('\\') || container.include?('..')
      return if public_container.blank?
      return unless container.casecmp(public_container).zero?

      raise ConfigurationError, 'refusing the public media container'
    end

    def self.build_directories
      require 'fog/openstack'

      auth_url = ENV['GROUP_CREATION_ICON_SWIFT_AUTH_URL'].presence || ENV['SWIFT_AUTH_URL'].presence
      username = ENV['GROUP_CREATION_ICON_SWIFT_USERNAME'].presence || ENV['SWIFT_USERNAME'].presence
      api_key = ENV['GROUP_CREATION_ICON_SWIFT_PASSWORD'].presence || ENV['SWIFT_PASSWORD'].presence
      raise ConfigurationError, 'missing private icon credentials' if auth_url.blank? || username.blank? || api_key.blank?

      Fog::Storage.new(
        provider: 'OpenStack',
        openstack_username: username,
        openstack_project_id: ENV['GROUP_CREATION_ICON_SWIFT_PROJECT_ID'].presence || ENV['SWIFT_PROJECT_ID'],
        openstack_project_name: ENV['GROUP_CREATION_ICON_SWIFT_TENANT'].presence || ENV['SWIFT_TENANT'],
        openstack_tenant: ENV['GROUP_CREATION_ICON_SWIFT_TENANT'].presence || ENV['SWIFT_TENANT'],
        openstack_api_key: api_key,
        openstack_auth_url: auth_url,
        openstack_domain_name: ENV['GROUP_CREATION_ICON_SWIFT_DOMAIN_NAME'].presence || ENV.fetch('SWIFT_DOMAIN_NAME', 'default'),
        openstack_region: ENV['GROUP_CREATION_ICON_SWIFT_REGION'].presence || ENV['SWIFT_REGION'],
        openstack_cache_ttl: ENV.fetch('SWIFT_CACHE_TTL', 60)
      ).directories
    end

    def initialize(container:, public_container:, directories:)
      self.class.validate_container!(container, public_container.to_s)
      @container = container
      @directories = directories
    end

    def write(key, io, content_type:)
      io.rewind if io.respond_to?(:rewind)
      directory.files.create(
        key: object_key(key),
        body: io,
        content_type: content_type,
        public: false
      )
    end

    def read(key)
      file = directory.files.get(object_key(key))
      raise NotFound, 'missing icon' if file.nil?

      body = file.body
      body.respond_to?(:read) ? body.read : body.to_s
    end

    def exist?(key)
      !directory.files.head(object_key(key)).nil?
    rescue NotFound
      false
    end

    def delete(key)
      file = directory.files.get(object_key(key))
      return :missing if file.nil?

      file.destroy
      :deleted
    end

    def local_path(_key)
      nil
    end

    def sweep_unreferenced(older_than:, now:)
      deleted = 0
      directory.files.each do |file|
        name = File.basename(file.key.to_s)
        next unless KEY_FORMAT.match?(name)
        modified = file.respond_to?(:last_modified) ? file.last_modified : nil
        next if modified.present? && modified > now - older_than
        next if yield(name)

        file.destroy
        deleted += 1
      end
      deleted
    end

    private

    def directory
      return @directory if defined?(@directory)

      found = @directories.get(@container)
      if found.nil?
        @directories.create(key: @container, public: false)
        found = @directories.get(@container)
      end
      raise ConfigurationError, 'cannot verify that the icon container blocks anonymous reads' unless private_container?(found)

      @directory = found
    end

    def private_container?(found)
      return false if found.nil?
      return false if found.respond_to?(:public?) && found.public?
      return false unless found.respond_to?(:read_acl)

      acl = found.read_acl
      return false if acl.nil?

      !public_read_acl?(acl)
    end

    def public_read_acl?(acl)
      acl.to_s.split(',').map(&:strip).any? do |part|
        part == '.rlistings' || part.start_with?('.r:')
      end
    end

    def object_key(key)
      GroupCreationIcons.relative_path(key)
    end
  end
end
