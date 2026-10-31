# frozen_string_literal: true

# Receive plus parse measurement for the synthetic public feed.
# This file does not boot Rails in the parent. A child process performs
# one read or one parse so its RSS is not the parent's copy of the fixture.
#
#   bundle exec ruby script/rss_parse_budget_measurement.rb
#   bundle exec ruby script/rss_parse_budget_measurement.rb --out=result.json
# A live public feed is not fetched here.

require 'English'
require 'json'
require 'socket'
require 'zlib'
require 'fileutils'
require 'tmpdir'

RUNS = 3
CHUNK = 8 * 1024
MIB = 1024 * 1024
RECEIVED_4 = 4 * MIB
INFLATED_4 = 4 * MIB
CANDIDATE_8 = 8 * MIB
def proc_kb(field)
  File.read('/proc/self/status')[/#{field}:\s+(\d+)/, 1].to_i
end

def load_parser!
  require 'active_support/all'
  require 'nokogiri'
  require 'logger'
  require 'addressable/uri'
  root = File.expand_path('../app/services/external_bridge', __dir__)
  files = Dir[File.join(root, 'error.rb'), File.join(root, 'rss', '**', '*.rb'), File.join(root, 'rss', '*.rb')].uniq
  pending = {}
  8.times do
    files.each do |file|
      next if pending[file] == :ok

      begin
        require file
        pending[file] = :ok
      rescue NameError, LoadError
        pending[file] = :later
      end
    end
  end
  raise 'parser did not load' unless defined?(ExternalBridge::RSS::Parser)
end

def sample_peak
  peak = proc_kb('VmRSS')
  stop = false
  thread = Thread.new do
    until stop
      rss = proc_kb('VmRSS')
      peak = rss if rss > peak
      sleep 0.01
    end
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  stop = true
  thread.join
  result.merge(elapsed_ms: elapsed_ms, sampled_peak_kb: peak, vmhwm_kb: proc_kb('VmHWM'))
end

if ARGV.first == '--parse' || ARGV.first == '--receive'
  $VERBOSE = nil
  require 'logger'
  module Rails
    def self.logger
      @logger ||= Logger.new(IO::NULL)
    end
  end
end

if ARGV.first == '--parse'
  load_parser!
  path = ARGV[1]
  limit = Integer(ARGV[2])
  threads = Integer(ARGV[3] || '1')
  GC.start
  rss_before = proc_kb('VmRSS')
  body = File.binread(path)
  rss_after_read = proc_kb('VmRSS')
  outcome = sample_peak do
    code = nil
    items = nil
    bytes = body.bytesize
    work = lambda do
      budget = ExternalBridge::RSS::DocumentBudget::Budget.default
      budget.max_bytes = limit
      budget.max_text_bytes = limit
      feed = ExternalBridge::RSS::Parser.parse!(body, budget: budget)
      [feed.items.size, 'ok']
    rescue ExternalBridge::Error => e
      [nil, e.code]
    end
    if threads <= 1
      items, code = work.call
    else
      results = Array.new(threads) { Thread.new { work.call } }.map(&:value)
      items = results.map(&:first).compact.max
      code = results.map(&:last).uniq.join(',')
    end
    { code: code, items: items, bytes: bytes }
  end
  puts JSON.generate(outcome.merge(mode: 'parse', rss_before_kb: rss_before, rss_after_read_kb: rss_after_read, threads: threads, rails_booted: false))
  exit 0
end

if ARGV.first == '--receive'
  require 'http'
  module ExternalBridge
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super(@code)
      end
    end
  end
  require_relative '../app/services/external_bridge/rss/body_reader'
  load_parser!
  port = Integer(ARGV[1])
  received = Integer(ARGV[2])
  inflated = Integer(ARGV[3])
  parse_limit = Integer(ARGV[4])
  GC.start
  rss_before = proc_kb('VmRSS')
  outcome = sample_peak do
    client = HTTP::Client.new
    code = nil
    items = nil
    bytes = nil
    begin
      response = client.get("http://127.0.0.1:#{port}/feed.xml")
      body = ExternalBridge::RSS::BodyReader.read!(response, received_limit: received, inflated_limit: inflated)
      bytes = body.bytesize
      budget = ExternalBridge::RSS::DocumentBudget::Budget.default
      budget.max_bytes = parse_limit
      budget.max_text_bytes = parse_limit
      feed = ExternalBridge::RSS::Parser.parse!(body, budget: budget)
      code = 'ok'
      items = feed.items.size
    rescue ExternalBridge::Error => e
      code = e.code
    ensure
      client.close
    end
    { code: code, items: items, bytes: bytes, auto_inflate: client.default_options.features.key?(:auto_inflate) }
  end
  puts JSON.generate(outcome.merge(mode: 'receive', rss_before_kb: rss_before, rails_booted: false))
  exit 0
end

if ARGV.first == '--rails'
  require File.expand_path('../config/environment', __dir__)
  path = ARGV[1]
  limit = Integer(ARGV[2])
  GC.start
  rss_before = proc_kb('VmRSS')
  body = File.binread(path)
  outcome = sample_peak do
    budget = ExternalBridge::RSS::DocumentBudget::Budget.default
    budget.max_bytes = limit
    budget.max_text_bytes = limit
    feed = ExternalBridge::RSS::Parser.parse!(body, budget: budget)
    { code: 'ok', items: feed.items.size, bytes: body.bytesize }
  rescue ExternalBridge::Error => e
    { code: e.code, items: nil, bytes: body.bytesize }
  end
  puts JSON.generate(outcome.merge(mode: 'rails', rss_before_kb: rss_before, rails_booted: true))
  exit 0
end

require 'active_support/core_ext/numeric/bytes'
require 'active_support/core_ext/numeric/time'
require_relative '../app/services/external_bridge/error'
require_relative '../app/services/external_bridge/rss/limits'
require_relative '../spec/support/rss_synthetic_feed'

def read_request(io)
  buffer = +''
  buffer << io.readpartial(1024) while !buffer.include?("\r\n\r\n") && buffer.bytesize < 65_536
  buffer
end

def serve(body, extra_headers)
  server = TCPServer.new('127.0.0.1', 0)
  payload = 0
  thread = Thread.new do
    client = server.accept
    read_request(client)
    headers = { 'Transfer-Encoding' => 'chunked', 'Connection' => 'close', 'Content-Type' => 'application/xml' }.merge(extra_headers)
    client.write("HTTP/1.1 200 OK\r\n#{headers.map { |key, value| "#{key}: #{value}" }.join("\r\n")}\r\n\r\n")
    offset = 0
    begin
      while offset < body.bytesize
        piece = body.byteslice(offset, CHUNK)
        offset += piece.bytesize
        client.write("#{piece.bytesize.to_s(16)}\r\n#{piece}\r\n")
        payload += piece.bytesize
      end
      client.write("0\r\n\r\n")
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    ensure
      client.close
    end
  end
  [server, thread, -> { payload }]
end

def child_json(*args, env: {})
  output = +''
  status = nil
  output = IO.popen(env, [RbConfig.ruby, __FILE__, *args], &:read)
  status = $CHILD_STATUS
  parsed = JSON.parse(output)
  parsed['client_status'] = status.exitstatus
  parsed
rescue JSON::ParserError
  { 'code' => 'child_failed', 'client_status' => status&.exitstatus, 'output' => output.to_s.byteslice(0, 500) }
end

def run_parse(path, limit, threads = 1)
  child_json('--parse', path, limit.to_s, threads.to_s)
end

def run_receive(body, headers, received, inflated, parse_limit)
  server, thread, payload = serve(body, headers)
  port = server.addr[1]
  result = child_json('--receive', port.to_s, received.to_s, inflated.to_s, parse_limit.to_s)
  thread.join(5)
  server.close
  result['payload_bytes_written'] = payload.call
  result
end

generate_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
document = ExternalBridge::RSS::SyntheticFeed.generate
generate_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - generate_started) * 1000).round(1)
compressed = Zlib.gzip(document)
fixture = File.join(Dir.tmpdir, 'rss-synthetic-feed.xml')
File.binwrite(fixture, document)
feed = ExternalBridge::RSS::SyntheticFeed
worst = feed.element_feed_open
worst << ('<e a="v"/>' * (ExternalBridge::RSS::Limits::MAX_XML_ELEMENTS - feed::ELEMENT_FEED_SHELL))
worst << '</channel></rss>'
worst_path = File.join(Dir.tmpdir, 'rss-structural-worst.xml')
File.binwrite(worst_path, worst)

scenarios = [
  ['parse_4mib', -> { run_parse(fixture, RECEIVED_4) }, 'oversized_feed', nil],
  ['parse_8mib', -> { run_parse(fixture, CANDIDATE_8) }, 'ok', ExternalBridge::RSS::Limits::MAX_ITEMS],
  ['parse_8mib_threads_5', -> { run_parse(fixture, CANDIDATE_8, 5) }, 'ok', ExternalBridge::RSS::Limits::MAX_ITEMS],
  ['worst_structure', -> { run_parse(worst_path, CANDIDATE_8) }, 'ok', ExternalBridge::RSS::Limits::MAX_ITEMS],
  ['worst_structure_threads_5', -> { run_parse(worst_path, CANDIDATE_8, 5) }, 'ok', ExternalBridge::RSS::Limits::MAX_ITEMS],
  ['receive_identity_4mib', -> { run_receive(document, {}, RECEIVED_4, INFLATED_4, RECEIVED_4) }, 'oversized_feed', nil],
  ['receive_identity_8mib', -> { run_receive(document, {}, CANDIDATE_8, CANDIDATE_8, CANDIDATE_8) }, 'ok', ExternalBridge::RSS::Limits::MAX_ITEMS],
  ['receive_gzip_4mib_inflated', -> { run_receive(compressed, { 'Content-Encoding' => 'gzip' }, CANDIDATE_8, INFLATED_4, INFLATED_4) }, 'oversized_feed', nil],
  ['receive_gzip_8mib', -> { run_receive(compressed, { 'Content-Encoding' => 'gzip' }, CANDIDATE_8, CANDIDATE_8, CANDIDATE_8) }, 'ok', ExternalBridge::RSS::Limits::MAX_ITEMS],
]

runs = scenarios.flat_map do |name, call, expected, items|
  times = name.include?('threads') ? 1 : RUNS
  times.times.map do |index|
    result = call.call
    result['scenario'] = name
    result['run'] = index + 1
    result['expected'] = expected
    result['pass'] = result['code'] == expected && result['client_status'].zero?
    result['pass'] &&= result['items'] == items if expected == 'ok'
    result['pass'] &&= result['bytes'] == document.bytesize if expected == 'ok' && result['bytes'] && !name.start_with?('worst_')
    result['pass'] = false if result['auto_inflate']
    warn("FAIL #{name} #{result.except('output')}") unless result['pass']
    result
  end
end

rails_runs = RUNS.times.map do |index|
  result = child_json('--rails', fixture, CANDIDATE_8.to_s, env: { 'RAILS_ENV' => ENV.fetch('RAILS_ENV', 'test') })
  result['scenario'] = 'rails_parse_8mib'
  result['run'] = index + 1
  result['expected'] = 'ok'
  result['pass'] = result['code'] == 'ok' && result['items'] == ExternalBridge::RSS::Limits::MAX_ITEMS && result['rails_booted'] == true
  warn("FAIL rails #{result.except('output')}") unless result['pass']
  result
end

summary = {
  ruby: RUBY_DESCRIPTION,
  nokogiri: Gem::Specification.find_by_name('nokogiri').version.to_s,
  http: Gem::Specification.find_by_name('http').version.to_s,
  zlib: Zlib::ZLIB_VERSION,
  uname: `uname -srm`.strip,
  nproc: `nproc`.strip,
  command: 'bundle exec ruby script/rss_parse_budget_measurement.rb',
  fixture_bytes: document.bytesize,
  fixture_items: ExternalBridge::RSS::SyntheticFeed::ITEMS,
  gzip_bytes: compressed.bytesize,
  fixture_generate_ms: generate_ms,
  product_max_parse_bytes: ExternalBridge::RSS::Limits::MAX_PARSE_BYTES,
  product_max_response_bytes: ExternalBridge::RSS::Limits::MAX_RESPONSE_BYTES,
  product_max_received_bytes: ExternalBridge::RSS::Limits::MAX_RECEIVED_BYTES,
  product_max_elements: ExternalBridge::RSS::Limits::MAX_XML_ELEMENTS,
  product_max_attributes_total: ExternalBridge::RSS::Limits::MAX_XML_ATTRIBUTES_TOTAL,
  structural_worst_bytes: worst.bytesize,
  note: 'parse and receive children do not boot Rails. rails_parse_8mib does. ' \
        'VmRSS is sampled during the timed section. rss_before_kb is after load and GC, before the timed work. ' \
        'A 5-thread run is one process, which is the Sidekiq shape, not five processes. ' \
        'The 4 MiB and 8 MiB figures passed to children are explicit byte budgets. product_max_* are Limits. ' \
        'worst_structure is 100_000 elements and one attribute on each filler, the accepted structural worst case. ' \
        'It is not the 6,107-element public-feed fixture.',
  runs: runs + rails_runs,
}

text = JSON.pretty_generate(summary)
puts text
out_arg = ARGV.find { |arg| arg.start_with?('--out=') }
File.write(out_arg.split('=', 2)[1], text) if out_arg
FileUtils.rm_f(fixture)
FileUtils.rm_f(worst_path)
exit((runs + rails_runs).all? { |run| run['pass'] } ? 0 : 1)
