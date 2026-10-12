# frozen_string_literal: true

require 'yaml'

# Static extraction for the settings-service audit.
# This does not boot Rails and does not read a database.
module SettingsServiceCatalog
  class Extract
    def initialize(root)
      @root = root
    end

    def call
      {
        yaml: yaml_defaults,
        decorator: decorator_keys,
        delegate: delegate_keys,
        permit: permit_keys,
        forms: forms,
        initial_state: initial_state_refs,
        js_meta: js_meta_exports,
        js_imports: js_imports,
        css_vars: css_setting_vars,
        html_classes: html_class_settings,
        reducer_groups: web_setting_groups,
        preferences_api: preferences_api,
        credentials: credentials_keys,
      }
    end

    private

    def read(relative)
      File.read(File.join(@root, relative))
    end

    def yaml_defaults
      loaded = YAML.safe_load(read('config/settings.yml'), aliases: true)
      defaults = loaded.fetch('defaults')
      line_index = {}
      read('config/settings.yml').lines.each_with_index do |line, index|
        next unless line =~ /\A  ([A-Za-z0-9_]+):/

        line_index[$1] ||= index + 1
      end
      defaults.map do |key, value|
        {
          'key' => key,
          'value' => value,
          'yaml_type' => yaml_type(value),
          'line' => line_index[key],
        }
      end
    end

    def yaml_type(value)
      case value
      when TrueClass, FalseClass then 'boolean'
      when Integer then 'integer'
      when Float then 'float'
      when String then 'string'
      when Array then 'array'
      when Hash then 'hash'
      when NilClass then 'nil'
      else value.class.name
      end
    end

    def percent_w(source, const_name)
      body = source[/#{const_name} = %w\(\s*(.*?)\s*\)\.freeze/m, 1]
      raise "missing #{const_name}" unless body

      body.scan(/[A-Za-z0-9_]+/)
    end

    def decorator_keys
      source = read('app/lib/user_settings_decorator.rb')
      line_of = {}
      source.lines.each_with_index do |line, index|
        stripped = line.strip
        next unless stripped =~ /\A[A-Za-z0-9_]+\z/

        line_of[stripped] ||= index + 1
      end
      {
        'profile' => percent_w(source, 'PROFILE_KEYS'),
        'nested' => percent_w(source, 'NESTED_KEYS'),
        'boolean' => percent_w(source, 'BOOLEAN_KEYS'),
        'string' => percent_w(source, 'STRING_KEYS'),
        'integer' => percent_w(source, 'INTEGER_KEYS'),
        'lines' => line_of,
        'normalize_line' => source.lines.index { |line| line.include?('def normalize_string_setting') } + 1,
      }
    end

    def delegate_keys
      source = read('app/models/user.rb')
      body = source[/delegate (.*?)to: :settings, prefix: :setting/m, 1]
      raise 'missing settings delegate' unless body

      keys = body.scan(/:([A-Za-z0-9_]+)/).flatten
      start = source.lines.index { |line| line.include?('delegate :auto_play_avatar') } + 1
      { 'keys' => keys, 'line' => start, 'duplicates' => keys.group_by(&:itself).select { |_key, values| values.size > 1 }.keys }
    end

    def permit_keys
      source = read('app/controllers/settings/preferences_controller.rb')
      body = source[/def user_settings_params(.*?)def set_account/m, 1]
      raise 'missing user_settings_params' unless body

      scalars = body.scan(/:setting_([A-Za-z0-9_]+)/).flatten
      nested = {}
      body.scan(/([a-z_]+): %i\(([^)]*)\)/).each do |name, inner|
        nested[name] = inner.scan(/[A-Za-z0-9_]+/)
      end
      user_columns = source[/def user_params(.*?)def user_settings_params/m, 1].scan(/:([A-Za-z0-9_]+)/).flatten
      {
        'scalars' => scalars,
        'nested' => nested,
        'user_columns' => user_columns,
        'line' => source.lines.index { |line| line.include?('def user_settings_params') } + 1,
      }
    end

    def forms
      paths = {
        'appearance' => 'app/views/settings/preferences/appearance/show.html.haml',
        'notifications' => 'app/views/settings/preferences/notifications/show.html.haml',
        'safety' => 'app/views/settings/preferences/safety/show.html.haml',
        'other' => 'app/views/settings/preferences/other/show.html.haml',
        'profile' => 'app/views/settings/profiles/show.html.haml',
      }
      paths.transform_values { |path| parse_form(path) }
    end

    def parse_form(path)
      lines = read(path).lines
      nested = nil
      conditions = []
      lines.each_with_index.filter_map do |line, index|
        indent = line[/\A */].size
        conditions.pop while conditions.any? && conditions.last[0] >= indent
        stripped = line.strip
        conditions << [indent, stripped] if stripped.start_with?('- if ', '- unless ')
        nested = line[/simple_fields_for :([A-Za-z0-9_]+)/, 1] if line.include?('simple_fields_for')
        match = line.match(/(\w+)\.input :([A-Za-z0-9_]+)/)
        next unless match

        commented = stripped.start_with?('-#', '#')
        receiver = match[1]
        {
          'name' => match[2],
          'nested' => receiver == 'f' ? nil : nested,
          'commented' => commented,
          'conditional' => !commented && conditions.any?,
          'condition' => conditions.last&.last,
          'line' => index + 1,
          'path' => path,
          'widget' => widget_kind(line),
        }
      end
    end

    def widget_kind(line)
      return 'boolean' if line.include?('as: :boolean')
      return 'radio' if line.include?('as: :radio_buttons')
      return 'check_boxes' if line.include?('as: :check_boxes')
      return 'range' if line.include?('as: :range')
      return 'text' if line.include?(':as => :text') || line.include?('as: :text')

      'unspecified'
    end

    def initial_state_refs
      source = read('app/serializers/initial_state_serializer.rb')
      refs = []
      section = nil
      source.lines.each_with_index do |line, index|
        section = 'meta' if line.match?(/\A  def meta\b/)
        section = 'compose' if line.match?(/\A  def compose\b/)
        section = 'search' if line.match?(/\A  def search\b/)
        section = 'other' if line.match?(/\A  def [a-z]/) && !line.match?(/\A  def (meta|compose|search)\b/)
        if line =~ /store\[:enable_local_timeline\]\s*=\s*false/
          refs << { 'var' => 'enable_local_timeline', 'line' => index + 1, 'literal' => false, 'text' => line.strip, 'section' => section }
        elsif line =~ /setting_([A-Za-z0-9_]+)/
          refs << { 'var' => $1, 'line' => index + 1, 'literal' => nil, 'text' => line.strip, 'section' => section }
        elsif line =~ /store\[:([A-Za-z0-9_]+)\]\s*=/
          refs << { 'var' => nil, 'meta' => $1, 'line' => index + 1, 'text' => line.strip, 'section' => section }
        end
      end
      compose = source[/def compose(.*?)def role/m, 1]
      search = source[/def search(.*?)def accounts/m, 1]
      {
        'setting_refs' => refs.select { |ref| ref['var'] },
        'meta_assignments' => refs.select { |ref| ref['meta'] },
        'compose_body' => compose,
        'search_body' => search,
      }
    end

    def js_meta_exports
      source = read('app/javascript/mastodon/initial_state.js')
      exports = []
      source.lines.each_with_index do |line, index|
        if line =~ /export const (\w+) = (?:normalize\w+\()?getMeta\('([A-Za-z0-9_]+)'\)/
          exports << { 'export' => $1, 'meta' => $2, 'line' => index + 1, 'number' => false }
        elsif line =~ /export const (\w+) = Number\(getMeta\('([A-Za-z0-9_]+)'\)\)/
          exports << { 'export' => $1, 'meta' => $2, 'line' => index + 1, 'number' => true }
        end
      end
      exports
    end

    def js_imports
      counts = Hash.new(0)
      files = Hash.new { |hash, key| hash[key] = [] }
      Dir.glob(File.join(@root, 'app/javascript/**/*.js')).each do |path|
        next if path.end_with?('/initial_state.js')

        text = File.read(path)
        text.scan(/import\s+(?:\{([^}]+)\}|(\w+))\s+from\s+['"]([^'"]*initial_state)['"]/).each do |named, default, _from|
          names = named ? named.scan(/[A-Za-z0-9_]+/) : [default]
          names.each do |name|
            counts[name] += 1
            files[name] << path.delete_prefix("#{@root}/")
          end
        end
      end
      { 'counts' => counts, 'files' => files }
    end

    def css_setting_vars
      source = read('app/helpers/accounts_helper.rb')
      vars = source.scan(/setting_([A-Za-z0-9_]+)/).flatten.uniq
      line = source.lines.index { |entry| entry.include?('def account_theme_valiables') } + 1
      { 'vars' => vars, 'line' => line }
    end

    def html_class_settings
      lines = read('app/helpers/application_helper.rb').lines
      indexes = method_indexes(lines, 'def body_classes', 'def cdn_host') + method_indexes(lines, 'def instance_ticker_css', 'def render_initial_state')
      vars = indexes.filter_map do |index|
        next unless lines[index] =~ /setting_([A-Za-z0-9_]+)/

        { 'var' => $1, 'line' => index + 1 }
      end
      theme_line = read('app/controllers/application_controller.rb').lines.index { |line| line.include?('def current_theme') } + 1
      { 'vars' => vars, 'theme_line' => theme_line }
    end

    def method_indexes(lines, start_snippet, end_snippet)
      start_at = lines.index { |line| line.include?(start_snippet) }
      end_at = lines.index { |line| line.include?(end_snippet) }
      return [] unless start_at && end_at && end_at > start_at

      (start_at...end_at).to_a
    end

    def web_setting_groups
      source = read('app/javascript/mastodon/reducers/settings.js')
      start = source.lines.index { |line| line.include?('const initialState = ImmutableMap({') }
      raise 'missing web settings initialState' unless start

      groups = []
      depth = 0
      source.lines.each_with_index do |line, index|
        next if index < start

        if index == start
          depth = 1
          next
        end
        break if depth.zero?

        if depth == 1 && line =~ /\A  ([A-Za-z0-9_]+):/
          groups << { 'key' => $1, 'line' => index + 1 }
        end
        depth += line.count('{') - line.count('}')
        depth -= 1 if line.strip == '});'
      end
      groups
    end

    def preferences_api
      source = read('app/serializers/rest/preferences_serializer.rb')
      pairs = []
      source.lines.each_with_index do |line, index|
        next unless line =~ /key: '([^']+)'/

        pairs << { 'api_key' => $1, 'line' => index + 1, 'text' => line.strip }
      end
      { 'keys' => pairs, 'oauth_line' => read('app/controllers/api/v1/preferences_controller.rb').lines.index { |line| line.include?('doorkeeper_authorize!') } + 1 }
    end

    def credentials_keys
      source = read('app/controllers/api/v1/accounts/credentials_controller.rb')
      {
        'source_settings' => source.scan(/'(setting_[A-Za-z0-9_]+)'/).flatten.uniq,
        'line' => source.lines.index { |line| line.include?('def user_settings_params') } + 1,
        'show_line' => source.lines.index { |line| line.include?('def show') } + 1,
      }
    end
  end
end
