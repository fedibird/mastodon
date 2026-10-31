# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationIcons::Storage do
  include ExternalBridgeIconHelpers

  around do |example|
    Dir.mktmpdir do |dir|
      ClimateControl.modify(GROUP_CREATION_ICON_ROOT: dir, GROUP_CREATION_ICON_STORAGE: 'filesystem', S3_ENABLED: nil, SWIFT_ENABLED: nil) do
        @icon_root = dir
        example.run
      end
    end
  end

  it 'stores bytes outside the public web root and reads them back' do
    storage = described_class.resolve
    key = GroupCreationIcons.generate_key
    bytes = icon_image('png')

    storage.write(key, StringIO.new(bytes), content_type: 'image/png')
    path = storage.local_path(key)

    expect(path.to_s).to start_with(@icon_root)
    expect(path.to_s).not_to include('/public/')
    expect(File.fnmatch?('*/group-creation-icons/??/??/*', path.to_s)).to be true
    expect(storage.read(key)).to eq bytes
    expect(storage.delete(key)).to eq :deleted
    expect(storage.delete(key)).to eq :missing
  end

  it 'refuses a root inside the public directory or the Paperclip directory' do
    expect { GroupCreationIcons::Filesystem.open(root: Rails.public_path) }.to raise_error(GroupCreationIcons::ConfigurationError)
    expect { GroupCreationIcons::Filesystem.open(root: Rails.public_path.join('system')) }.to raise_error(GroupCreationIcons::ConfigurationError)
  end

  it 'fails closed when public object storage is on and no private location is configured' do
    ClimateControl.modify(S3_ENABLED: 'true', GROUP_CREATION_ICON_STORAGE: nil) do
      expect(described_class.available?).to be false
      expect { described_class.resolve }.to raise_error(GroupCreationIcons::ConfigurationError)
    end

    ClimateControl.modify(SWIFT_ENABLED: 'true', S3_ENABLED: nil, GROUP_CREATION_ICON_STORAGE: nil) do
      expect(described_class.available?).to be false
    end
  end

  it 'still allows an explicit private filesystem while S3 is the public media store' do
    ClimateControl.modify(S3_ENABLED: 'true', GROUP_CREATION_ICON_STORAGE: 'filesystem') do
      expect(described_class.available?).to be true
      expect(described_class.resolve).to be_a(GroupCreationIcons::Filesystem)
    end
  end

  it 'refuses the public S3 bucket and writes only to the private bucket' do
    client = object_double
    expect do
      GroupCreationIcons::S3.new(bucket: 'Media', client: client, public_bucket: 'media')
    end.to raise_error(GroupCreationIcons::ConfigurationError)

    ClimateControl.modify(GROUP_CREATION_ICON_S3_BUCKET: 'media', S3_BUCKET: 'media') do
      expect { GroupCreationIcons::S3.from_env }.to raise_error(GroupCreationIcons::ConfigurationError)
    end

    calls = []
    client = private_s3_client(calls)

    storage = GroupCreationIcons::S3.new(bucket: 'private-icons', client: client, public_bucket: 'mastodon-public', server_side_encryption: 'AES256')
    key = GroupCreationIcons.generate_key
    storage.write(key, StringIO.new('png-bytes'), content_type: 'image/png')

    expect(calls.first[:bucket]).to eq 'private-icons'
    expect(calls.first[:acl]).to eq 'private'
    expect(calls.first[:cache_control]).to eq 'private, no-store'
    expect(calls.first[:server_side_encryption]).to eq 'AES256'
    expect(calls.first[:key]).to eq GroupCreationIcons.relative_path(key)
    expect(calls.first[:key]).not_to include('png-bytes')
    expect(storage.local_path(key)).to be_nil
  end

  it 'refuses an S3 bucket whose policy allows anonymous reads, even under another name' do
    calls = []
    client = private_s3_client(calls, policy: public_read_policy, policy_public: false)
    storage = GroupCreationIcons::S3.new(bucket: 'another-icons', client: client, public_bucket: 'mastodon-public')

    expect { storage.write(GroupCreationIcons.generate_key, StringIO.new('png'), content_type: 'image/png') }.to raise_error(GroupCreationIcons::ConfigurationError)
    expect(calls).to be_empty
  end

  it 'refuses an S3 bucket when public access cannot be verified' do
    client = Class.new do
      def get_public_access_block(*)
        raise StandardError, 'access denied'
      end

      def put_object(*)
        raise 'must not write'
      end
    end.new
    storage = GroupCreationIcons::S3.new(bucket: 'unchecked-icons', client: client, public_bucket: 'mastodon-public')

    expect { storage.write(GroupCreationIcons.generate_key, StringIO.new('png'), content_type: 'image/png') }.to raise_error(GroupCreationIcons::ConfigurationError)
  end

  it 'reads Swift ACLs from head_container, which fog-openstack 0.3.10 directories do not expose' do
    require 'fog/openstack'
    Fog::Storage::OpenStack
    require 'fog/storage/openstack/models/directory'
    expect(Fog::Storage::OpenStack::Directory.method_defined?(:read_acl)).to be false

    expect do
      GroupCreationIcons::Swift.new(container: 'Media', public_container: 'media', service: Object.new)
    end.to raise_error(GroupCreationIcons::ConfigurationError)

    puts = []
    service = swift_head_service(puts, 'X-Container-Read' => nil)
    storage = GroupCreationIcons::Swift.new(container: 'private-icons', public_container: 'mastodon-public', service: service)
    key = GroupCreationIcons.generate_key
    storage.write(key, StringIO.new('png'), content_type: 'image/png')

    expect(puts.size).to eq 1
    expect(puts.first[:object]).to eq GroupCreationIcons.relative_path(key)
    expect(puts.first[:options]['Content-Type']).to eq 'image/png'
  end

  it 'refuses a Swift container with a public read ACL or an unverifiable HEAD' do
    puts = []
    ['.r:*', '.rlistings', :fail, :no_headers].each do |acl|
      service = swift_head_service(puts, acl)
      storage = GroupCreationIcons::Swift.new(container: 'shared-but-public', public_container: 'mastodon-public', service: service)

      expect { storage.write(GroupCreationIcons.generate_key, StringIO.new('png'), content_type: 'image/png') }.to raise_error(GroupCreationIcons::ConfigurationError)
    end
    expect(puts).to be_empty
  end

  it 'sweeps old unreferenced files and keeps a saved request' do
    storage = described_class.resolve
    requester = Fabricate(:user)
    old_key = GroupCreationIcons.generate_key
    fresh_key = GroupCreationIcons.generate_key
    saved_key = GroupCreationIcons.generate_key
    bytes = icon_image('png')
    [old_key, fresh_key, saved_key].each { |key| storage.write(key, StringIO.new(bytes), content_type: 'image/png') }
    FileUtils.touch(storage.local_path(old_key), mtime: 2.days.ago.to_time)

    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'kepticon',
      display_name: 'Kept',
      note: 'kept',
      icon_storage_key: saved_key,
      icon_content_type: 'image/png',
      icon_byte_size: bytes.bytesize,
      submission_token: SecureRandom.uuid
    )

    expect(GroupCreationIcons::Sweep.call).to eq 1
    expect(storage.exist?(old_key)).to be false
    expect(storage.exist?(fresh_key)).to be true
    expect(storage.exist?(saved_key)).to be true
  end

  def object_double
    Object.new
  end

  def private_s3_client(calls, policy: nil, policy_public: false)
    no_policy = Class.new(StandardError)
    no_policy.define_singleton_method(:name) { 'Aws::S3::Errors::NoSuchBucketPolicy' }
    Class.new do
      define_method(:initialize) do
        @calls = calls
        @policy = policy
        @policy_public = policy_public
        @no_policy = no_policy
      end

      def put_object(options)
        @calls << options
      end

      def get_public_access_block(*)
        config = Struct.new(:block_public_acls, :ignore_public_acls, :block_public_policy, :restrict_public_buckets).new(true, true, true, true)
        Struct.new(:public_access_block_configuration).new(config)
      end

      def get_bucket_policy(*)
        return Struct.new(:policy).new(@policy) if @policy

        raise @no_policy, 'missing'
      end

      def get_bucket_policy_status(*)
        raise @no_policy, 'missing' if @policy.nil? && !@policy_public

        Struct.new(:policy_status).new(Struct.new(:is_public).new(@policy_public))
      end
    end.new
  end

  def swift_head_service(puts, acl)
    Class.new do
      define_method(:initialize) { @puts = puts }
      define_method(:head_container) do |_|
        raise StandardError, 'head failed' if acl == :fail
        return Struct.new(:headers).new(nil) if acl == :no_headers

        headers = {}
        headers['X-Container-Read'] = acl unless acl.nil?
        Struct.new(:headers).new(headers)
      end
      define_method(:put_object) do |_container, object, _data, options = {}|
        @puts << { object: object, options: options }
      end
    end.new
  end

  def public_read_policy
    {
      'Version' => '2012-10-17',
      'Statement' => [
        { 'Effect' => 'Allow', 'Principal' => '*', 'Action' => 's3:GetObject', 'Resource' => 'arn:aws:s3:::another-icons/*' },
      ],
    }.to_json
  end
end
