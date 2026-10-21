# frozen_string_literal: true

module ExternalBridge
  module VisibilityMigration
    # Operator checkpoint. Ids and counts only. Atomic replace, mode 0600.
    # A file from another database, instance, scope, or direction is refused.
    class Checkpoint
      ALLOWED_KEYS = %w(
        version database instance scope direction
        high_watermark_marker_id last_completed_marker_id pending_batch
      ).freeze
      SCOPE_KEYS = %w(user_id subscription_id).freeze
      PENDING_KEYS = %w(marker_ids status_ids first_marker_id last_marker_id).freeze

      attr_reader :path, :data

      def self.identity
        {
          'database' => ActiveRecord::Base.connection.select_value('SELECT current_database()').to_s,
          'instance' => Rails.configuration.x.local_domain.to_s,
        }
      end

      def initialize(path)
        @path = path
        @data = nil
      end

      def exist?
        File.exist?(path)
      end

      def load!(expected_scope)
        refuse!(:checkpoint_symlink, 'checkpoint path is a symlink') if File.symlink?(path)
        parsed = with_lock { parse_file }
        identity = self.class.identity
        refuse!(:checkpoint_database, 'checkpoint database does not match this database') if parsed['database'] != identity['database']
        refuse!(:checkpoint_instance, 'checkpoint instance does not match this instance') if parsed['instance'] != identity['instance']
        refuse!(:checkpoint_direction, 'checkpoint direction is not personal_to_external') if parsed['direction'] != DIRECTION
        refuse!(:checkpoint_scope, 'checkpoint scope does not match these filters') if parsed['scope'] != expected_scope
        @data = parsed
        self
      end

      def create!(expected_scope, watermark)
        identity = self.class.identity
        @data = {
          'version' => CHECKPOINT_VERSION,
          'database' => identity['database'],
          'instance' => identity['instance'],
          'scope' => expected_scope,
          'direction' => DIRECTION,
          'high_watermark_marker_id' => watermark,
          'last_completed_marker_id' => 0,
          'pending_batch' => nil,
        }
        save!
        self
      end

      def watermark
        data['high_watermark_marker_id']
      end

      def last_completed
        data['last_completed_marker_id']
      end

      def pending_batch
        data['pending_batch']
      end

      def mark_pending!(batch)
        data['pending_batch'] = {
          'marker_ids' => batch[:marker_ids],
          'status_ids' => batch[:status_ids],
          'first_marker_id' => batch[:first_marker_id],
          'last_marker_id' => batch[:last_marker_id],
        }
        save!
      end

      def complete_batch!(last_marker_id)
        data['last_completed_marker_id'] = last_marker_id
        data['pending_batch'] = nil
        save!
      end

      private

      def parse_file
        refuse!(:checkpoint_missing, 'checkpoint file is missing') unless File.file?(path)
        parsed = JSON.parse(File.read(path))
        refuse!(:checkpoint_shape, 'checkpoint is not an object') unless parsed.is_a?(Hash)
        unknown = parsed.keys - ALLOWED_KEYS
        refuse!(:checkpoint_shape, 'checkpoint has unknown keys') if unknown.any?
        refuse!(:checkpoint_version, 'checkpoint version is not supported') unless parsed['version'] == CHECKPOINT_VERSION
        refuse!(:checkpoint_shape, 'checkpoint scope is invalid') unless valid_scope?(parsed['scope'])
        refuse!(:checkpoint_shape, 'checkpoint watermark is invalid') unless positive_or_zero?(parsed['high_watermark_marker_id'])
        refuse!(:checkpoint_shape, 'checkpoint cursor is invalid') unless positive_or_zero?(parsed['last_completed_marker_id'])
        refuse!(:checkpoint_shape, 'checkpoint pending batch is invalid') unless valid_pending?(parsed['pending_batch'])
        parsed
      rescue JSON::ParserError
        refuse!(:checkpoint_corrupt, 'checkpoint file is not valid JSON')
      end

      def valid_scope?(scope)
        return false unless scope.is_a?(Hash) && (scope.keys - SCOPE_KEYS).empty?

        %w(user_id subscription_id).all? { |key| scope[key].nil? || positive_id?(scope[key]) }
      end

      def valid_pending?(pending)
        return true if pending.nil?
        return false unless pending.is_a?(Hash) && (pending.keys - PENDING_KEYS).empty?
        return false unless id_list?(pending['marker_ids'], allow_empty: false) && id_list?(pending['status_ids'], allow_empty: true)

        positive_id?(pending['first_marker_id']) && positive_id?(pending['last_marker_id'])
      end

      def id_list?(values, allow_empty:)
        values.is_a?(Array) && (allow_empty || values.any?) && values.all? { |value| positive_id?(value) }
      end

      def positive_id?(value)
        value.is_a?(Integer) && value.positive?
      end

      def positive_or_zero?(value)
        value.is_a?(Integer) && value >= 0
      end

      def save!
        with_lock { replace_file! }
      end

      def with_lock
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory)
        lock_path = "#{path}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def replace_file!
        directory = File.dirname(path)
        refuse!(:checkpoint_symlink, 'checkpoint path is a symlink') if File.symlink?(path)
        temporary = File.join(directory, ".#{File.basename(path)}.#{Process.pid}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.generate(data))
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
        File.chmod(0o600, path)
      rescue StandardError
        File.delete(temporary) if defined?(temporary) && temporary && File.file?(temporary)
        raise
      end

      def refuse!(code, message)
        raise Refusal.new(code, message)
      end
    end
  end
end
