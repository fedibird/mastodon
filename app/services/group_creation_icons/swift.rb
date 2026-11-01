# frozen_string_literal: true

module GroupCreationIcons
  # A dedicated Swift container. Privacy is the container read ACL from
  # HEAD, not an object flag. fog-openstack 0.3.10 Directory has no
  # read_acl, and Directories#get lists every object, so ACL checks use
  # Fog::Storage#head_container only.
  class Swift
    PAGE_SIZE = 1_000

    def self.from_env
      container = ENV['GROUP_CREATION_ICON_SWIFT_CONTAINER'].to_s.strip
      public_container = ENV['SWIFT_CONTAINER'].to_s.strip
      validate_container!(container, public_container)
      raise ConfigurationError, 'refusing a public icon container' if ActiveModel::Type::Boolean.new.cast(ENV['GROUP_CREATION_ICON_SWIFT_PUBLIC'])

      new(container: container, public_container: public_container, service: build_service)
    end

    def self.validate_container!(container, public_container)
      raise ConfigurationError, 'missing private icon container' if container.blank?
      raise ConfigurationError, 'invalid private icon container' if container.include?('/') || container.include?('\\') || container.include?('..')
      return if public_container.blank?
      return unless container.casecmp(public_container).zero?

      raise ConfigurationError, 'refusing the public media container'
    end

    def self.build_service
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
      )
    end

    def initialize(container:, public_container:, service:)
      self.class.validate_container!(container, public_container.to_s)
      @container = container
      @service = service
    end

    def write(key, io, content_type:)
      ensure_private_container!
      io.rewind if io.respond_to?(:rewind)
      @service.put_object(@container, object_key(key), io.read, 'Content-Type' => content_type)
    end

    def read(key)
      response = @service.get_object(@container, object_key(key))
      body = response.body
      body.respond_to?(:read) ? body.read : body.to_s
    rescue StandardError => e
      raise NotFound, 'missing icon' if missing_object?(e)

      raise
    end

    def exist?(key)
      @service.head_object(@container, object_key(key))
      true
    rescue StandardError => e
      return false if missing_object?(e)

      raise
    end

    def delete(key)
      @service.delete_object(@container, object_key(key))
      :deleted
    rescue StandardError => e
      return :missing if missing_object?(e)

      raise
    end

    def local_path(_key)
      nil
    end

    # One GET per page of object names. Swift stops a listing at `limit`,
    # so a single call would leave later orphans in place. Marker is the
    # last name returned, including names we delete, so the next page is
    # not skipped and this page is not repeated.
    def sweep_unreferenced(older_than:, now:, page_size: PAGE_SIZE, &referenced)
      deleted = 0
      marker = nil
      previous_marker = nil
      loop do
        entries = container_page(marker, page_size)
        break if entries.empty?

        entries.each { |entry| deleted += 1 if delete_unreferenced(entry, older_than, now, &referenced) }
        last_name = entries.last['name'].to_s
        break if entries.size < page_size || last_name.blank? || last_name == previous_marker

        previous_marker = last_name
        marker = last_name
      end
      deleted
    end

    private

    def container_page(marker, page_size)
      options = { 'prefix' => 'group-creation-icons/', 'limit' => page_size }
      options['marker'] = marker if marker.present?
      Array(@service.get_container(@container, options).body)
    end

    def delete_unreferenced(entry, older_than, now)
      name = File.basename(entry['name'].to_s)
      return false unless KEY_FORMAT.match?(name)

      modified = entry['last_modified']
      return false if modified.present? && Time.zone.parse(modified.to_s) > now - older_than
      return false if yield(name)

      delete(name)
      true
    end

    def ensure_private_container!
      response = head_container
      acl = container_read_header(response)
      raise ConfigurationError, 'cannot verify that the icon container blocks anonymous reads' if acl.nil?
      raise ConfigurationError, 'refusing a container that allows anonymous reads' if public_read_acl?(acl)
    rescue ConfigurationError
      raise
    rescue StandardError
      raise ConfigurationError, 'cannot verify that the icon container blocks anonymous reads'
    end

    def head_container
      @service.head_container(@container)
    rescue StandardError => e
      raise unless missing_object?(e)

      @service.put_container(@container, public: false)
      @service.head_container(@container)
    end

    def container_read_header(response)
      headers = response.respond_to?(:headers) ? response.headers : nil
      return nil unless headers.respond_to?(:keys) && headers.respond_to?(:[])

      key = headers.keys.find { |name| name.to_s.casecmp('X-Container-Read').zero? }
      key ? headers[key].to_s : ''
    end

    def public_read_acl?(acl)
      acl.to_s.split(',').map(&:strip).any? do |part|
        part == '.rlistings' || part.start_with?('.r:')
      end
    end

    def missing_object?(error)
      error.class.name.to_s.end_with?('NotFound')
    end

    def object_key(key)
      GroupCreationIcons.relative_path(key)
    end
  end
end
