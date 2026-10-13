# frozen_string_literal: true

module SettingsServiceCatalog
  class NineKeyWriteAudit
    KEYS = %w(
      default_privacy default_sensitive default_language show_translation_bar
      translation_preferred_mode new_features_policy content_font_size info_font_size
      reduce_motion
    ).freeze
    ROOTS = %w(app lib config db script bin).freeze
    # Path plus reason. Not line numbers: a moved method stays allowed.
    ALLOW = {
      'app/lib/user_preferences/writer.rb' => 'writer_internal_setting_save',
      'app/lib/user_settings_decorator.rb' => 'decorator_refuses_nine_keys_without_legacy_writer',
      'app/lib/settings/scoped_settings.rb' => 'generic_store_still_accepts_any_var',
      'app/models/form/admin_settings.rb' => 'site_setting_not_a_user_nine_key',
      'app/models/form/action_review_settings.rb' => 'site_setting_not_a_user_nine_key',
      'db/migrate/20190314181829_migrate_open_registrations_setting.rb' => 'historical_site_setting_migration',
    }.freeze

    Finding = Struct.new(:path, :line, :kind, :detail, keyword_init: true)

    def initialize(root)
      @root = root
    end

    def call
      violations = []
      reviews = []
      scanned = 0
      each_source do |path, text|
        scanned += 1
        text.each_line.with_index(1) do |line, number|
          classify(path, number, line, violations, reviews)
        end
      end
      {
        'scanned_files' => scanned,
        'violations' => violations,
        'reviews' => reviews,
        'ok' => violations.empty? && reviews.all? { |finding| ALLOW.key?(finding.path) },
      }
    end

    def scan_content(path, text)
      violations = []
      reviews = []
      text.each_line.with_index(1) do |line, number|
        classify(path, number, line, violations, reviews)
      end
      { 'violations' => violations, 'reviews' => reviews }
    end

    private

    def each_source
      ROOTS.each do |relative|
        dir = File.join(@root, relative)
        next unless File.directory?(dir)

        Dir.glob(File.join(dir, '**', '*')).each do |full|
          next unless File.file?(full)
          next if File.extname(full) == '.yml' && relative == 'config' && full.end_with?('settings.yml')
          next unless text_file?(full)
          next if File.size(full) > 1_000_000
          next if full.end_with?('nine_key_write_audit.rb')

          yield relative_path(full), File.read(full, encoding: 'UTF-8', invalid: :replace, undef: :replace)
        end
      end
    end

    def text_file?(path)
      return true if %w(.rb .rake .haml .erb).include?(File.extname(path))
      return false unless File.extname(path).empty? && path.include?('/bin/')

      !File.binread(path, 512).to_s.include?("\0")
    end

    def relative_path(full)
      full.delete_prefix("#{@root}/")
    end

    def classify(path, number, line, violations, reviews)
      stripped = line.strip
      return if stripped.start_with?('#')

      literal = literal_nine_key_write(stripped)
      if literal
        violations << Finding.new(path: path, line: number, kind: 'literal_nine_key_write', detail: literal) unless ALLOW.key?(path)
        return
      end

      detail = dynamic_write(stripped)
      return unless detail

      reviews << Finding.new(path: path, line: number, kind: 'dynamic_write', detail: detail)
    end

    def literal_nine_key_write(line)
      KEYS.each do |key|
        return key if line.match?(/settings\s*\[\s*[:'"]#{key}['"]?\s*\]\s*=(?!=)/)
        return key if line.match?(/\.settings\s*\.\s*#{key}\s*=(?!=)/)
        return key if line.match?(/\bsetting_#{key}\s*=(?!=)/)
      end
      nil
    end

    def dynamic_write(line)
      return 'settings index assignment' if line.match?(/\.settings\s*\[\s*(?!['":])/) && line.include?('=')
      return 'scoped settings method assignment' if line.match?(/self\[\s*var_name\s*\]\s*=/)
      return 'setting row initialize' if line.include?('Setting.unscoped.new')
      return 'setting row delete' if line.include?('Setting.unscoped') && line.include?('delete_all')
      return 'dynamic setting initialize' if line.include?('first_or_initialize(var:')

      nil
    end
  end
end
