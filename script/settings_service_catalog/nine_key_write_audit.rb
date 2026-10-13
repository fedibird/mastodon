# frozen_string_literal: true

require 'digest'
require 'ripper'

module SettingsServiceCatalog
  module NineKeyTemplateScan
    module_function

    def scan(text, keys)
      findings = []
      assign = /(?:\|\|=|&&=|\+=|=)(?!=)/
      text.scan(/settings\s*\[[^\]]{0,200}\]\s*#{assign}/m) do
        snippet = Regexp.last_match(0)
        key = keys.find { |item| snippet.include?(item) }
        if key && snippet.match?(/['":]#{Regexp.escape(key)}['"]/)
          findings << [:violation, 'literal_nine_key_write', snippet.gsub(/\s+/, ' '), key]
        elsif !snippet.match?(/\[\s*['":]/)
          findings << [:review, 'settings_index', snippet.gsub(/\s+/, ' '), 'dynamic index']
        end
      end
      text.scan(/settings\s*\.\s*([A-Za-z_]\w*)\s*#{assign}/) do
        name = Regexp.last_match(1)
        snippet = Regexp.last_match(0).gsub(/\s+/, ' ')
        findings << [:violation, 'literal_nine_key_write', snippet, name] if keys.include?(name)
      end
      text.scan(/settings\s*\.\s*#\{[^}]{0,80}\}\s*#{assign}/m) do
        findings << [:review, 'dynamic_setter', Regexp.last_match(0).gsub(/\s+/, ' '), 'dynamic setter']
      end
      text.scan(/Setting(?:\.unscoped)?(?:\.[\w]+|\([^)]{0,400}\)){0,6}\.(?:update_all|create!?|insert_all!?|upsert_all!?|delete_all)/m) do
        snippet = Regexp.last_match(0)
        key = keys.find { |item| snippet.include?(item) }
        findings << if key
                      [:violation, 'literal_setting_write', snippet.gsub(/\s+/, ' '), key]
                    else
                      [:review, 'setting_persist', snippet.gsub(/\s+/, ' '), 'setting call']
                    end
      end
      findings
    end

    def digest(node)
      strip_positions(node).inspect
    end

    def line_of(node)
      found = nil
      walk_line(node) { |number| found ||= number }
      found
    end

    def strip_positions(node)
      return node unless node.is_a?(Array)
      return node[1] if node[0].to_s.start_with?('@')

      node.map { |child| strip_positions(child) }
    end

    def walk_line(node, &block)
      return unless node.is_a?(Array)

      if node[0].to_s.start_with?('@') && node[2].is_a?(Array) && node[2][0].is_a?(Integer)
        yield node[2][0]
      end
      node.each { |child| walk_line(child, &block) if child.is_a?(Array) }
    end
  end

  class NineKeyWriteAudit
    KEYS = %w(
      default_privacy default_sensitive default_language show_translation_bar
      translation_preferred_mode new_features_policy content_font_size info_font_size
      reduce_motion
    ).freeze
    ROOTS = %w(app lib config db script bin).freeze
    SETTER_SENDS = %w(public_send send __send__).freeze
    PERSIST_CALLS = %w(
      update_all update! update update_columns update_attribute update_attributes
      create create! insert_all insert_all! upsert_all upsert_all! delete_all
      destroy_all save save!
    ).freeze
    SQL_WRITE = /\b(?:UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+["'`]?settings\b/i
    Finding = Struct.new(:path, :line, :defn, :kind, :shape, :detail, :literal, keyword_init: true)

    # One entry per dynamic write. shape_sha is the statement shape, so a
    # changed or added write does not stay allowed. Literal nine-key writes
    # are never listed here.
    ALLOW = [
      { path: 'app/lib/settings/scoped_settings.rb', method: 'method_missing', kind: 'settings_index', shape_sha: '3a1b26686721806cf85c4e9979868778eb5f4d8d948f29f54187a179739cc139', reason: 'scoped_settings_method_missing' },
      { path: 'app/lib/settings/scoped_settings.rb', method: '[]=', kind: 'setting_persist', shape_sha: 'beadadabe6438fdc7e5d819530e768fb7c2b8b796aeba5b41397cefebbcfa9a0', reason: 'scoped_settings_generic_store' },
      { path: 'app/lib/user_preferences/writer.rb', method: 'insert_row', kind: 'setting_persist', shape_sha: '48602c03225e4f961e9de5c3cd3f45488abbd359d815c59dc1e9f7e0cf2565ee', reason: 'writer_internal_insert' },
      { path: 'app/lib/user_preferences/writer.rb', method: 'update_row', kind: 'setting_persist', shape_sha: '8734b346c313f49f66fa4e70527c5f2cfd7881def70afd5ae0b56c28db3f172e', reason: 'writer_internal_update' },
      { path: 'app/lib/user_preferences/writer.rb', method: 'delete_row', kind: 'setting_persist', shape_sha: '017bf783592ccd745e8e66574cf88ce3b8b7826c74ec15f0e9cdfef54e7bf6d1', reason: 'writer_internal_delete' },
      { path: 'app/lib/user_settings_decorator.rb', method: 'process_update', kind: 'settings_index', shape_sha: 'd8f79b2d89bbd7243800b582934968b27f8939e540b4c6edcfe33982b0c89ac3', reason: 'decorator_nested_merge' },
      { path: 'app/lib/user_settings_decorator.rb', method: 'process_update', kind: 'settings_index', shape_sha: 'f936ebc5a1e603486272cb67ffa22d7dc6dda997466b1e9f6c708b907630415c', reason: 'decorator_non_nine_string' },
      { path: 'app/lib/user_settings_decorator.rb', method: 'process_update', kind: 'settings_index', shape_sha: 'ea736a03c405c4700c29d998b68d62b3828777cd041b52482e790e6673b1a3d6', reason: 'decorator_non_nine_boolean' },
      { path: 'app/models/form/admin_settings.rb', method: 'save', kind: 'setting_persist', shape_sha: '317c741d95e2bbdf709d26e8100b48c8ef8c585cb07b54fe2a4ae34cf365c485', reason: 'site_setting_keys_not_user_nine_keys' },
    ].freeze

    def initialize(root)
      @root = root
    end

    def call
      violations = []
      reviews = []
      scanned = 0
      each_source do |path, text|
        scanned += 1
        found = scan_text(path, text)
        violations.concat(found[:violations])
        reviews.concat(found[:reviews])
      end
      report(scanned, violations, reviews)
    end

    def scan_content(path, text)
      found = scan_text(path, text)
      report(1, found[:violations], found[:reviews])
    end

    private

    def report(scanned, violations, reviews)
      allowed, unlisted = partition_reviews(reviews)
      {
        'scanned_files' => scanned,
        'violations' => violations,
        'reviews' => reviews,
        'allowed_reviews' => allowed,
        'unlisted_reviews' => unlisted,
        'ok' => violations.empty? && unlisted.empty? && inventory_exact?(reviews),
      }
    end

    def inventory_exact?(reviews)
      reviews.map { |finding| fingerprint(finding) }.sort == ALLOW.map { |entry| [entry[:path], entry[:method], entry[:kind], entry[:shape_sha]] }.sort
    end

    def partition_reviews(reviews)
      allowed = []
      unlisted = []
      reviews.each do |finding|
        (allowed_entry(finding) ? allowed : unlisted) << finding
      end
      [allowed, unlisted]
    end

    def allowed_entry(finding)
      ALLOW.find { |entry| fingerprint(finding) == [entry[:path], entry[:method], entry[:kind], entry[:shape_sha]] }
    end

    def fingerprint(finding)
      [finding.path, finding.defn, finding.kind, Digest::SHA256.hexdigest(finding.shape)]
    end

    def each_source
      ROOTS.each do |relative|
        dir = File.join(@root, relative)
        next unless File.directory?(dir)

        Dir.glob(File.join(dir, '**', '*')).each do |full|
          next unless File.file?(full)
          next unless text_file?(full)
          next if File.size(full) > 1_000_000

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

    def scan_text(path, text)
      violations = []
      reviews = []
      if ruby_source?(path)
        sexp = Ripper.sexp(text)
        if sexp
          walk(sexp, path, violations, reviews)
        else
          scan_fallback(path, text, violations, reviews)
        end
        flag_site_key_list(path, text, violations)
      else
        scan_fallback(path, text, violations, reviews)
      end
      { violations: violations, reviews: reviews }
    end

    def flag_site_key_list(path, text, violations)
      return unless path.end_with?('app/models/form/admin_settings.rb')

      body = text[/KEYS = %i\((.*?)\)/m].to_s
      hit = KEYS.find { |key| body.match?(/\b#{Regexp.escape(key)}\b/) }
      return unless hit

      add(violations, path, [:site_keys, hit], 'save', 'literal_nine_key_write', body, hit, true)
    end

    def ruby_source?(path)
      %w(.rb .rake).include?(File.extname(path)) || File.extname(path).empty?
    end

    def walk(node, path, violations, reviews)
      return unless node.is_a?(Array)

      if node[0] == :program
        collect_persists(node, path, '<main>', {}, violations, reviews)
      end
      case node[0]
      when :def
        collect_persists(node[3], path, ident_text(node[1]), {}, violations, reviews)
      when :defs
        collect_persists(node[4], path, ident_text(node[3]), {}, violations, reviews)
      else
        node.each { |child| walk(child, path, violations, reviews) if child.is_a?(Array) }
      end
    end

    def collect_persists(node, path, method_name, locals, violations, reviews)
      return unless node.is_a?(Array)

      if node[0] == :assign && node[1].is_a?(Array) && node[1][0] == :var_field
        local = ident_text(node[1][1])
        locals[local] = node[2] if setting_origin?(node[2])
      end
      note_write(node, path, method_name, locals, violations, reviews)
      persist_children(node).each do |child|
        next unless child.is_a?(Array)
        next if %i(def defs).include?(child[0])

        collect_persists(child, path, method_name, locals, violations, reviews)
      end
    end

    def persist_children(node)
      return [] unless node.is_a?(Array)
      return [node[2]].compact if node[0] == :method_add_arg

      node
    end

    def complete_call?(node)
      node.is_a?(Array) && %i(method_add_arg call command command_call).include?(node[0])
    end

    def note_write(node, path, method_name, locals, violations, reviews)
      index_write(node, path, method_name, violations, reviews)
      setter_send(node, path, method_name, violations, reviews)
      setting_call(node, path, method_name, locals, violations, reviews)
      sql_write(node, path, method_name, violations, reviews)
    end

    # ScopedSettings#method_missing treats a call ending in "=" as a write:
    # user.settings.default_privacy = value becomes self['default_privacy'] = value.
    # :field is that setter. :opassign (||=, +=, &&=) can call it too.
    def index_write(node, path, method_name, violations, reviews)
      return unless node.is_a?(Array) && %i(assign opassign).include?(node[0])

      lhs = node[1]
      return unless lhs.is_a?(Array)

      case lhs[0]
      when :aref_field
        classify_index(node, lhs, path, method_name, violations, reviews)
      when :field
        classify_field(node, lhs, path, method_name, violations, reviews)
      end
    end

    def classify_index(node, lhs, path, method_name, violations, reviews)
      receiver = lhs[1]
      return unless settings_receiver?(receiver) || (self_receiver?(receiver) && method_name == 'method_missing')

      label = static_label(first_arg(lhs[2]))
      if label[:literal] && KEYS.include?(label[:value])
        add(violations, path, node, method_name, 'literal_nine_key_write', digest(node), label[:value], true)
      elsif label[:literal]
        nil
      else
        add(reviews, path, node, method_name, 'settings_index', digest(node), 'dynamic index', false)
      end
    end

    def classify_field(node, lhs, path, method_name, violations, reviews)
      return unless settings_receiver?(lhs[1])

      name = ident_text(lhs[3])
      if name && KEYS.include?(name)
        add(violations, path, node, method_name, 'literal_nine_key_write', digest(node), name, true)
      elsif name.nil?
        add(reviews, path, node, method_name, 'dynamic_setter', digest(node), 'dynamic setter', false)
      end
    end

    def setter_send(node, path, method_name, violations, reviews)
      return unless complete_call?(node)

      call = unwrap_call(node)
      return unless call && SETTER_SENDS.include?(call[:name])
      return unless settings_receiver?(call[:receiver])

      label = static_label(first_arg(call[:args]))
      name = setter_name(label)
      if name && KEYS.include?(name)
        add(violations, path, node, method_name, 'literal_setter_send', digest(node), name, true)
      elsif name
        nil
      elsif label[:dynamic]
        add(reviews, path, node, method_name, 'dynamic_setter', digest(node), 'dynamic setter', false)
      end
    end

    def setting_call(node, path, method_name, locals, violations, reviews)
      return unless complete_call?(node)

      call = unwrap_call(node)
      return unless call && PERSIST_CALLS.include?(call[:name])

      origin = setting_receiver?(call[:receiver]) ? call[:receiver] : locals[receiver_name(call[:receiver])]
      return unless origin

      labels = var_labels(origin) + var_labels(call[:args])
      literals = labels.select { |label| label[:literal] }.map { |label| label[:value] }
      dynamic = labels.any? { |label| label[:dynamic] } || literals.empty?
      if literals.any? { |value| KEYS.include?(value) }
        add(violations, path, node, method_name, 'literal_setting_write', digest(node), literals.join(','), true)
      elsif dynamic
        add(reviews, path, node, method_name, 'setting_persist', "#{digest(origin)}|#{digest(node)}", call[:name], false)
      end
    end

    def sql_write(node, path, method_name, violations, reviews)
      text = sql_text(node)
      return unless text&.match?(SQL_WRITE)
      return unless node[0] == :string_literal || node[0] == :xstring_literal

      hit = KEYS.find { |key| text.match?(/\b#{Regexp.escape(key)}\b/) }
      if hit
        add(violations, path, node, method_name, 'literal_sql_write', digest(node), hit, true)
      else
        add(reviews, path, node, method_name, 'dynamic_sql', digest(node), 'settings sql', false)
      end
    end

    def add(list, path, node, method_name, kind, shape, detail, literal)
      list << Finding.new(path: path, line: line_of(node), defn: method_name, kind: kind, shape: shape, detail: detail, literal: literal)
    end

    def setting_origin?(node)
      call = unwrap_call(node)
      return false unless call
      return false unless setting_receiver?(node) || call_name(call[:receiver]) == 'thing_scoped'

      %w(new create create! where find_by find_by! find_or_initialize_by find_or_create_by first_or_initialize first_or_create unscoped).include?(call[:name])
    end

    def settings_receiver?(node)
      call = unwrap_call(node)
      return true if call && call[:name] == 'settings'
      return true if node.is_a?(Array) && node[0] == :vcall && ident_text(node[1]) == 'settings'

      false
    end

    def self_receiver?(node)
      node.is_a?(Array) && node[0] == :var_ref && node[1].is_a?(Array) && node[1][0] == :@kw && node[1][1] == 'self'
    end

    def setting_receiver?(node)
      return false unless node.is_a?(Array)
      return true if const_path(node) == 'Setting'

      consts = []
      pointer = node
      while pointer.is_a?(Array)
        call = unwrap_call(pointer)
        break unless call

        consts << const_path(call[:receiver])
        pointer = call[:receiver]
      end
      consts.compact.any? { |path| path == 'Setting' }
    end

    def const_path(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :var_ref
        node[1].is_a?(Array) && node[1][0] == :@const ? node[1][1] : nil
      when :top_const_ref
        node[1].is_a?(Array) ? node[1][1] : nil
      when :const_path_ref
        parent = const_path(node[1])
        name = node[2].is_a?(Array) ? node[2][1] : nil
        parent && name ? "#{parent}::#{name}" : name
      when :call, :method_add_arg
        call = unwrap_call(node)
        call && const_path(call[:receiver])
      end
    end

    def var_labels(node)
      labels = []
      walk_vars(node, labels)
      labels
    end

    def walk_vars(node, labels)
      return unless node.is_a?(Array)

      if node[0] == :assoc_new && label_name(node[1]) == 'var'
        labels << static_label(node[2])
      elsif node[0] == :assoc_new && literal_string(node[1]) == 'var'
        labels << static_label(node[2])
      else
        node.each { |child| walk_vars(child, labels) if child.is_a?(Array) }
      end
    end

    def static_label(node)
      text = literal_string(node)
      return { literal: true, value: text, dynamic: false } if text
      return { literal: false, value: nil, dynamic: false } unless node.is_a?(Array)

      dynamic = node.flatten.any? { |part| %i(string_embexpr dyna_symbol).include?(part) }
      value = literal_pieces(node).join
      { literal: !dynamic && !value.empty? && node[0] != :vcall && node[0] != :var_ref, value: value, dynamic: dynamic || node[0] == :vcall || node[0] == :var_ref || node[0] == :call }
    end

    def setter_name(label)
      return nil unless label[:literal] && label[:value].to_s.end_with?('=')

      label[:value].delete_suffix('=').delete_prefix('setting_')
    end

    def literal_string(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :string_literal
        return nil if node.flatten.include?(:string_embexpr)

        literal_pieces(node).join
      when :symbol_literal
        find_ident(node)
      when :@tstring_content, :@ident
        node[1]
      end
    end

    def find_ident(node)
      return nil unless node.is_a?(Array)
      return node[1] if node[0] == :@ident

      node.each do |child|
        next unless child.is_a?(Array)

        found = find_ident(child)
        return found if found
      end
      nil
    end

    def literal_pieces(node)
      pieces = []
      return pieces unless node.is_a?(Array)

      pieces << node[1] if node[0] == :@tstring_content
      node.each { |child| pieces.concat(literal_pieces(child)) if child.is_a?(Array) }
      pieces
    end

    def label_name(node)
      return node[1].to_s.delete_suffix(':') if node.is_a?(Array) && node[0] == :@label

      nil
    end

    def unwrap_call(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :method_add_arg
        inner = unwrap_call(node[1])
        return nil unless inner

        inner.merge(args: node[2])
      when :call
        { name: ident_text(node[3]), receiver: node[1], args: nil }
      when :command_call
        { name: ident_text(node[3]), receiver: node[1], args: node[4] }
      when :fcall
        { name: ident_text(node[1]), receiver: nil, args: nil }
      when :command
        { name: ident_text(node[1]), receiver: nil, args: node[2] }
      end
    end

    def first_arg(args)
      return nil unless args.is_a?(Array)

      body = args[0] == :arg_paren ? args[1] : args
      return nil unless body.is_a?(Array)

      list = body[0] == :args_add_block ? body[1] : body
      list.is_a?(Array) ? list[0] : nil
    end

    def call_name(node)
      return ident_text(node[1]) if node.is_a?(Array) && node[0] == :vcall

      unwrap_call(node)&.fetch(:name, nil)
    end

    def receiver_name(node)
      return nil unless node.is_a?(Array) && node[0] == :var_ref

      ident_text(node[1])
    end

    def ident_text(node)
      return node if node.is_a?(String)
      return node[1] if node.is_a?(Array) && %i(@ident @const @kw @op).include?(node[0])

      nil
    end

    def sql_text(node)
      return nil unless node.is_a?(Array) && node[0] == :string_literal

      literal_pieces(node).join
    end

    def digest(node)
      NineKeyTemplateScan.digest(node)
    end

    def line_of(node)
      NineKeyTemplateScan.line_of(node)
    end

    def scan_fallback(path, text, violations, reviews)
      NineKeyTemplateScan.scan(text, KEYS).each do |severity, kind, shape, detail|
        list = severity == :violation ? violations : reviews
        add(list, path, [:fallback, shape], '<template>', kind, shape, detail, severity == :violation)
      end
    end
  end
end
