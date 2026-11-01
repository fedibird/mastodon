# frozen_string_literal: true

module GroupCreationIcons
  # Original bytes outside the web root. A shared disk is required when more
  # than one host must read, cancel, or (in P2) copy the same icon.
  class Filesystem
    def self.open(root: Storage.filesystem_root)
      new(root).tap(&:ensure_private!)
    end

    def initialize(root)
      @root = Pathname.new(root)
    end

    def ensure_private!
      FileUtils.mkdir_p(@root)
      real_root = @root.realpath
      public_root = Rails.public_path.realpath
      paperclip_root = paperclip_public_root
      if inside?(real_root, public_root) || (paperclip_root && inside?(real_root, paperclip_root))
        raise ConfigurationError, 'refusing to store group icons in a public directory'
      end

      File.chmod(0o700, real_root) if File.owned?(real_root)
      @root = real_root
    end

    def write(key, io, content_type:)
      raise Error, 'missing content type' if content_type.blank?

      path = path_for(key)
      FileUtils.mkdir_p(path.dirname)
      File.chmod(0o700, path.dirname) if File.owned?(path.dirname)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode
        file.write(read_body(io))
      end
      path
    end

    def byte_size(key)
      path = path_for(key)
      raise NotFound, 'missing icon' unless File.file?(path)

      File.size(path)
    end

    def read(key)
      raise Error, 'too_large' if byte_size(key) >= GroupCreationIcons::MAX_BYTES

      File.binread(path_for(key))
    end

    def exist?(key)
      File.file?(path_for(key))
    rescue Error
      false
    end

    def delete(key)
      path = path_for(key)
      File.unlink(path)
      :deleted
    rescue Errno::ENOENT
      :missing
    end

    def local_path(key)
      path_for(key)
    end

    def sweep_unreferenced(older_than:, now:)
      deleted = 0
      pattern = @root.join('group-creation-icons', '??', '??', '*')
      Dir.glob(pattern.to_s).each do |candidate|
        next unless File.file?(candidate)
        key = File.basename(candidate)
        next unless KEY_FORMAT.match?(key)
        next if File.mtime(candidate) > now - older_than
        next if yield(key)

        File.unlink(candidate)
        deleted += 1
      rescue Errno::ENOENT
        next
      end
      deleted
    end

    private

    def path_for(key)
      relative = GroupCreationIcons.relative_path(key)
      path = @root.join(relative)
      expanded = path.expand_path
      prefix = @root.to_s + File::SEPARATOR
      raise Error, 'invalid icon path' unless expanded.to_s.start_with?(prefix)

      expanded
    end

    def read_body(io)
      io.rewind if io.respond_to?(:rewind)
      body = io.read
      io.rewind if io.respond_to?(:rewind)
      body.to_s.b
    end

    def inside?(path, parent)
      path.to_s == parent.to_s || path.to_s.start_with?(parent.to_s + File::SEPARATOR)
    end

    def paperclip_public_root
      configured = ENV['PAPERCLIP_ROOT_PATH'].presence
      raw = configured || Rails.root.join('public', 'system').to_s
      expanded = Pathname.new(raw.to_s.gsub(':rails_root', Rails.root.to_s)).expand_path
      expanded.exist? ? expanded.realpath : expanded
    rescue Errno::ENOENT
      nil
    end
  end
end
