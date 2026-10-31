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
    client = Class.new do
      def initialize(calls)
        @calls = calls
      end

      def put_object(options)
        @calls << options
      end
    end.new(calls)

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

  it 'refuses the public Swift container and marks objects private' do
    expect do
      GroupCreationIcons::Swift.new(container: 'Media', public_container: 'media', directories: double)
    end.to raise_error(GroupCreationIcons::ConfigurationError)

    created = []
    files = Class.new do
      def initialize(created)
        @created = created
      end

      def create(attrs)
        @created << attrs
      end
    end.new(created)
    directory = Struct.new(:files).new(files)
    directories = Struct.new(:directory).new(directory)
    directories.define_singleton_method(:get) { |_name| directory }

    storage = GroupCreationIcons::Swift.new(container: 'private-icons', public_container: 'mastodon-public', directories: directories)
    storage.write(GroupCreationIcons.generate_key, StringIO.new('png'), content_type: 'image/png')

    expect(created.first[:public]).to be false
    expect(created.first[:key]).to start_with('group-creation-icons/')
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
end
