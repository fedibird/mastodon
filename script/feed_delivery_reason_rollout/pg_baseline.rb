# frozen_string_literal: true

module FeedDeliveryReasonRollout
  module_function

  # Uses the Rails connection for RAILS_ENV. Never prints a URL, user, or password.
  def pg_baseline_command(argv)
    options = {}
    OptionParser.new do |parser|
      parser.on('--out PATH') { |value| options[:out] = value }
    end.parse!(argv)
    raise Error, 'unexpected arguments' unless argv.empty?
    raise Error, '--out PATH is required' if options[:out].to_s.empty?

    write_pg_baseline(options[:out])
  end

  def write_pg_baseline(path)
    require File.join(APP_ROOT, 'config/environment')
    expected = ActiveRecord::Base.connection_db_config.database.to_s
    raise Error, 'Rails database name is unset' if expected.empty?

    selects = select_statements(File.read(File.join(APP_ROOT, 'script/feed_delivery_reason_pg_baseline.sql')))
    body = nil
    begin
      body = read_only_baseline(expected, selects)
    rescue ActiveRecord::ActiveRecordError, PG::Error
      raise Error, 'read-only baseline could not use the Rails database'
    end
    write_new_file(path, body)
    puts "Saved read-only PostgreSQL baseline: #{path} (database=#{expected}; credentials not printed)"
    0
  end

  def select_statements(sql)
    statements = sql.gsub(/--[^\n]*/, '').split(';').map(&:strip).reject(&:empty?)
    selects = []
    statements.each do |statement|
      case statement
      when /\ASELECT\b/i
        selects << statement
      when /\ABEGIN\b/i, /\ACOMMIT\b/i, /\AROLLBACK\b/i
        nil
      else
        raise Error, 'baseline SQL contains a statement that is not a read-only SELECT'
      end
    end
    raise Error, 'baseline SQL has no SELECT' if selects.empty?

    selects
  end

  def read_only_baseline(expected, selects)
    connection = ActiveRecord::Base.connection_pool.checkout
    raw = connection.raw_connection
    began = false
    chunks = []
    begin
      raw.exec('BEGIN TRANSACTION READ ONLY')
      began = true
      assert_same_database!(raw, expected)
      selects.each { |statement| chunks << format_pg_result(raw.exec(statement)) }
      chunks.join("\n")
    ensure
      raw.exec('ROLLBACK') if began
      ActiveRecord::Base.connection_pool.checkin(connection)
    end
  end

  def assert_same_database!(raw, expected)
    raise Error, 'Rails database name is unset' if expected.to_s.empty?

    actual = raw.exec('SELECT current_database()').getvalue(0, 0).to_s
    raise Error, 'connected database does not match the Rails database' unless actual == expected
  end

  def format_pg_result(result)
    lines = [result.fields.join("\t")]
    rows = result.values
    rows.each do |row|
      lines << row.map { |value| value.nil? ? '' : value.to_s }.join("\t")
    end
    "#{lines.join("\n")}\n"
  end
end
