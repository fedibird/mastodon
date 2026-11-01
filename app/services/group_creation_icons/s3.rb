# frozen_string_literal: true

module GroupCreationIcons
  # A dedicated bucket. The public media bucket is refused even with a
  # private ACL or a different prefix. Objects are read through the app,
  # never through a public or presigned URL.
  class S3
    def self.from_env
      bucket = ENV['GROUP_CREATION_ICON_S3_BUCKET'].to_s.strip
      public_bucket = ENV['S3_BUCKET'].to_s.strip
      acl = ENV.fetch('GROUP_CREATION_ICON_S3_ACL', 'private')
      encryption = ENV.fetch('GROUP_CREATION_ICON_S3_SSE', 'AES256')
      encryption = nil if encryption == 'off'
      validate_bucket!(bucket, public_bucket)
      raise ConfigurationError, 'refusing a public icon ACL' unless %w(private omit).include?(acl)

      new(bucket: bucket, client: build_client, public_bucket: public_bucket, acl: acl, server_side_encryption: encryption)
    end

    def self.validate_bucket!(bucket, public_bucket)
      raise ConfigurationError, 'missing private icon bucket' if bucket.blank?
      raise ConfigurationError, 'invalid private icon bucket' if bucket.include?('/') || bucket.include?('\\') || bucket.include?('..')
      return if public_bucket.blank?
      return unless bucket.casecmp(public_bucket).zero?

      raise ConfigurationError, 'refusing the public media bucket'
    end

    def self.build_client
      require 'aws-sdk-s3'

      access_key = ENV['GROUP_CREATION_ICON_S3_ACCESS_KEY_ID'].presence || ENV['AWS_ACCESS_KEY_ID'].presence
      secret_key = ENV['GROUP_CREATION_ICON_S3_SECRET_ACCESS_KEY'].presence || ENV['AWS_SECRET_ACCESS_KEY'].presence
      raise ConfigurationError, 'missing private icon credentials' if access_key.blank? || secret_key.blank?

      options = {
        region: ENV['GROUP_CREATION_ICON_S3_REGION'].presence || ENV.fetch('S3_REGION', 'us-east-1'),
        access_key_id: access_key,
        secret_access_key: secret_key,
      }
      endpoint = ENV['GROUP_CREATION_ICON_S3_ENDPOINT'].presence || ENV['S3_ENDPOINT'].presence
      if endpoint.present?
        options[:endpoint] = endpoint
        options[:force_path_style] = ENV['GROUP_CREATION_ICON_S3_FORCE_PATH_STYLE'] != 'false'
      end
      Aws::S3::Client.new(options)
    end

    def initialize(bucket:, client:, public_bucket:, acl: 'private', server_side_encryption: 'AES256')
      self.class.validate_bucket!(bucket, public_bucket.to_s)
      raise ConfigurationError, 'refusing a public icon ACL' unless %w(private omit).include?(acl)
      raise ConfigurationError, 'refusing a public icon hostname' if public_hostname_configured?

      @bucket = bucket
      @client = client
      @acl = acl
      @server_side_encryption = server_side_encryption.presence
    end

    def write(key, io, content_type:)
      ensure_private_bucket!
      @client.put_object(put_options(key, io, content_type))
    end

    def byte_size(key)
      response = @client.head_object(bucket: @bucket, key: object_key(key))
      response.content_length
    rescue StandardError => e
      raise NotFound, 'missing icon' if e.class.name.end_with?('NotFound', 'NoSuchKey')

      raise
    end

    def read(key)
      raise Error, 'too_large' if byte_size(key).to_i >= GroupCreationIcons::MAX_BYTES

      response = @client.get_object(bucket: @bucket, key: object_key(key))
      body = response.body
      body.respond_to?(:read) ? body.read : body.to_s
    rescue NotFound, Error
      raise
    rescue StandardError => e
      raise NotFound, 'missing icon' if e.class.name.end_with?('NoSuchKey')

      raise
    end

    def exist?(key)
      @client.head_object(bucket: @bucket, key: object_key(key))
      true
    rescue StandardError => e
      return false if e.class.name.end_with?('NotFound', 'NoSuchKey')

      raise
    end

    def delete(key)
      @client.delete_object(bucket: @bucket, key: object_key(key))
      :deleted
    end

    def local_path(_key)
      nil
    end

    def sweep_unreferenced(older_than:, now:)
      deleted = 0
      token = nil
      loop do
        params = { bucket: @bucket, prefix: 'group-creation-icons/', max_keys: 100 }
        params[:continuation_token] = token if token
        page = @client.list_objects_v2(**params)
        contents = page.respond_to?(:contents) ? page.contents : []
        contents.each do |entry|
          key = entry_key(entry)
          next if key.blank?
          next if entry_time(entry) > now - older_than
          next if yield(key)

          delete(key)
          deleted += 1
        end
        break unless page.respond_to?(:is_truncated) && page.is_truncated && page.next_continuation_token.present?

        token = page.next_continuation_token
      end
      deleted
    end

    private

    def public_hostname_configured?
      ENV['GROUP_CREATION_ICON_S3_ALIAS_HOST'].present? || ENV['GROUP_CREATION_ICON_S3_CLOUDFRONT_HOST'].present?
    end

    def ensure_private_bucket!
      configuration = @client.get_public_access_block(bucket: @bucket).public_access_block_configuration
      policy_json, policy_public = bucket_policy_evidence
      return if S3Access.public_read_blocked?(block_configuration: configuration, policy_json: policy_json, policy_status_public: policy_public)

      raise ConfigurationError, 'refusing a bucket that allows anonymous reads'
    rescue ConfigurationError
      raise
    rescue StandardError
      raise ConfigurationError, 'cannot verify that the icon bucket blocks anonymous reads'
    end

    def bucket_policy_evidence
      policy_json = nil
      policy_public = false
      begin
        policy_json = @client.get_bucket_policy(bucket: @bucket).policy
      rescue StandardError => e
        raise unless no_such_bucket_policy?(e)
      end
      begin
        policy_public = @client.get_bucket_policy_status(bucket: @bucket).policy_status.is_public
      rescue StandardError => e
        raise unless no_such_bucket_policy?(e)
      end
      [policy_json, policy_public]
    end

    def no_such_bucket_policy?(error)
      error.class.name.to_s.end_with?('NoSuchBucketPolicy')
    end

    def put_options(key, io, content_type)
      io.rewind if io.respond_to?(:rewind)
      options = {
        bucket: @bucket,
        key: object_key(key),
        body: io,
        content_type: content_type,
        cache_control: 'private, no-store',
      }
      options[:acl] = 'private' if @acl == 'private'
      options[:server_side_encryption] = @server_side_encryption if @server_side_encryption
      options
    end

    def object_key(key)
      GroupCreationIcons.relative_path(key)
    end

    def entry_key(entry)
      raw = entry.respond_to?(:key) ? entry.key.to_s : entry[:key].to_s
      name = File.basename(raw)
      name if KEY_FORMAT.match?(name)
    end

    def entry_time(entry)
      raw = entry.respond_to?(:last_modified) ? entry.last_modified : entry[:last_modified]
      raw || Time.zone.at(0)
    end
  end
end
