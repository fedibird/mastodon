# frozen_string_literal: true

# Names for the opt-in Elasticsearch spec.
#
# The spec must not purge or delete GroupDirectoryIndex. A temporary name
# is the only index it may create, and delete_temporary! refuses any other
# name, including the configured directory index.
class GroupDirectory::LiveIndex
  PREFIX = 'group_directory_es_live_'

  class UnsafeIndex < StandardError; end

  class << self
    def temporary_name(real_name)
      name = "#{PREFIX}#{SecureRandom.hex(8)}"
      refuse!(name, real_name)
      name
    end

    def delete_temporary!(client, name, real_name)
      refuse!(name, real_name)
      return unless client.indices.exists?(index: name)

      client.indices.delete(index: name)
    end

    private

    def refuse!(name, real_name)
      real = real_name.to_s
      candidate = name.to_s
      return if candidate.start_with?(PREFIX) && candidate != real

      raise UnsafeIndex, 'refusing to touch the configured group directory index'
    end
  end
end
