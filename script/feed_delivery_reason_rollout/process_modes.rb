# frozen_string_literal: true

module FeedDeliveryReasonRollout
  module_function

  # Linux read-only process inspection. Prints ONLY the feature flag, never any
  # other /proc/PID/environ entries (which may contain credentials).
  def process_modes_command(argv)
    options = { pids: [], units: [] }
    OptionParser.new do |parser|
      parser.on('--pid PID', Integer) { |value| options[:pids] << value }
      parser.on('--unit NAME') { |value| options[:units] << value }
      parser.on('--expect PHASE', PHASES) { |value| options[:expect] = value }
    end.parse!(argv)
    raise Error, 'unexpected arguments' unless argv.empty?
    raise Error, 'provide one or more --pid or --unit' if options[:pids].empty? && options[:units].empty?

    options[:units].each do |unit|
      raise Error, "invalid unit name: #{unit}" unless unit.match?(/\A[a-zA-Z0-9@_.-]+\z/)

      output, error, status = Open3.capture3('systemctl', 'show', '--property=MainPID', '--value', unit)
      raise Error, "systemctl could not read #{unit}: #{error.strip}" unless status.success?

      pid = Integer(output.strip, 10, exception: false)
      raise Error, "#{unit} has no running MainPID" unless pid&.positive?

      options[:pids] << pid
      puts "unit=#{unit} main_pid=#{pid} (verify additional worker units/processes separately)"
    end
    mismatch = false
    options[:pids].uniq.each do |pid|
      raise Error, "invalid PID: #{pid}" unless pid.positive?

      entry = File.binread("/proc/#{pid}/environ").split("\0").find { |item| item.start_with?("#{MODE_ENV}=") }
      raw = entry&.split('=', 2)&.last
      normalized = raw.to_s.strip.downcase
      effective = PHASES.include?(normalized) ? normalized : 'off'
      note = if raw.nil? || normalized.empty?
               ' (unset/blank)'
             elsif PHASES.include?(normalized)
               ''
             else
               ' (invalid value, normalized to off)'
             end
      puts "pid=#{pid} #{MODE_ENV}=#{effective}#{note}"
      mismatch ||= effective != options[:expect] if options[:expect]
    end
    mismatch ? 3 : 0
  end

  def check_pids_command(argv)
    options = {}
    OptionParser.new do |parser|
      parser.on('--start PATH') { |value| options[:start] = value }
      parser.on('--end PATH') { |value| options[:end] = value }
    end.parse!(argv)
    raise Error, 'unexpected arguments' unless argv.empty?
    raise Error, '--start and --end are required' if options.values_at(:start, :end).any? { |value| value.to_s.empty? }

    started = File.read(options[:start])
    ended = File.read(options[:end])
    if unit_pids(started).empty? && unit_pids(ended).empty?
      warn 'NOTE: no unit MainPID was recorded, so process replacement was not checked.'
      return 0
    end

    changes = pid_changes(started, ended)
    if changes.empty?
      puts 'pid_stability=unchanged'
      return 0
    end

    warn 'INCOMPLETE: a listed unit MainPID changed between the start and end checks.'
    changes.each { |change| warn "  - #{change}" }
    warn 'A restart that is not one of these MainPIDs is still invisible; check service logs.'
    3
  end

  def pid_changes(start_text, end_text)
    started = unit_pids(start_text)
    ended = unit_pids(end_text)
    (started.keys | ended.keys).sort.filter_map do |unit|
      next if started[unit] && started[unit] == ended[unit]

      "#{unit} main_pid #{started[unit] || 'missing'} -> #{ended[unit] || 'missing'}"
    end
  end

  def unit_pids(text)
    pairs = text.to_s.each_line.filter_map do |line|
      match = line.match(/\Aunit=(\S+) main_pid=(\d+)\b/)
      [match[1], match[2]] if match
    end
    pairs.to_h
  end
end
