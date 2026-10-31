# frozen_string_literal: true

# Measures the feed receive/inflate path. This process does not boot Rails
# and does not load Nokogiri. A child process performs one HTTP.rb read so
# its RSS is not the parent's copy of the fixture.
#
#   bundle exec ruby script/rss_receive_budget_measurement.rb

require 'json'
require 'socket'
require 'zlib'

RUNS = 3
CHUNK = 8 * 1024
MIB = 1024 * 1024
RECEIVED_4 = 4 * MIB
INFLATED_4 = 4 * MIB
CANDIDATE_8 = 8 * MIB

if ARGV.first == '--client'
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

  port = Integer(ARGV[1])
  received = Integer(ARGV[2])
  inflated = Integer(ARGV[3])
  GC.start
  rss_before = File.read('/proc/self/status')[/VmRSS:\s+(\d+)/, 1].to_i
  peak = rss_before
  stop = false
  sampler = Thread.new do
    until stop
      rss = File.read('/proc/self/status')[/VmRSS:\s+(\d+)/, 1].to_i
      peak = rss if rss > peak
      sleep 0.005
    end
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client = HTTP::Client.new
  code = nil
  bytes = nil
  begin
    response = client.get("http://127.0.0.1:#{port}/feed.xml")
    body = ExternalBridge::RSS::BodyReader.read!(response, received_limit: received, inflated_limit: inflated)
    code = 'ok'
    bytes = body.bytesize
  rescue ExternalBridge::Error => e
    code = e.code
  ensure
    client.close
  end
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
  stop = true
  sampler.join
  hwm = File.read('/proc/self/status')[/VmHWM:\s+(\d+)/, 1].to_i
  puts JSON.generate(
    code: code,
    bytes: bytes,
    elapsed_ms: elapsed_ms,
    rss_before_kb: rss_before,
    sampled_peak_kb: peak,
    vmhwm_kb: hwm,
    rails_booted: false,
    auto_inflate: client.default_options.features.key?(:auto_inflate)
  )
  exit 0
end

require_relative '../spec/support/rss_synthetic_feed'

def proc_kb(field)
  File.read('/proc/self/status')[/#{field}:\s+(\d+)/, 1].to_i
end

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
    headers = {
      'Transfer-Encoding' => 'chunked',
      'Connection' => 'close',
      'Content-Type' => 'application/xml',
    }.merge(extra_headers)
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
      client.close rescue nil
    end
  end
  [server, thread, -> { payload }]
end

def run_once(body, headers, received, inflated)
  server, thread, payload = serve(body, headers)
  port = server.addr[1]
  output = IO.popen([RbConfig.ruby, __FILE__, '--client', port.to_s, received.to_s, inflated.to_s], &:read)
  status = $?
  thread.join(5)
  server.close
  result = JSON.parse(output)
  result['payload_bytes_written'] = payload.call
  result['client_status'] = status.exitstatus
  result
end

generate_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
document = ExternalBridge::RSS::SyntheticFeed.generate
generate_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - generate_started) * 1000).round(1)
compressed = Zlib.gzip(document)

scenarios = [
  ['identity_4mib_reject', document, {}, RECEIVED_4, INFLATED_4, 'oversized_feed'],
  ['identity_8mib_candidate', document, {}, CANDIDATE_8, CANDIDATE_8, 'ok'],
  ['gzip_4mib_inflated_reject', compressed, { 'Content-Encoding' => 'gzip' }, CANDIDATE_8, INFLATED_4, 'oversized_feed'],
  ['gzip_8mib_candidate', compressed, { 'Content-Encoding' => 'gzip' }, CANDIDATE_8, CANDIDATE_8, 'ok'],
]

runs = scenarios.flat_map do |name, body, headers, received, inflated, expected|
  RUNS.times.map do |index|
    result = run_once(body, headers, received, inflated)
    result['scenario'] = name
    result['run'] = index + 1
    result['expected'] = expected
    result['pass'] = result['code'] == expected && result['client_status'].zero? && !result['auto_inflate']
    result['pass'] &&= result['bytes'] == document.bytesize if expected == 'ok'
    warn("FAIL #{result}") unless result['pass']
    result
  end
end

nokogiri = Gem::Specification.find_by_name('nokogiri').version.to_s
http_version = Gem::Specification.find_by_name('http').version.to_s
summary = {
  ruby: RUBY_DESCRIPTION,
  zlib: Zlib::ZLIB_VERSION,
  http: http_version,
  nokogiri: nokogiri,
  nokogiri_loaded: defined?(Nokogiri) ? true : false,
  rails_booted: defined?(Rails) ? true : false,
  uname: `uname -srm`.strip,
  nproc: `nproc`.strip,
  command: 'bundle exec ruby script/rss_receive_budget_measurement.rb',
  fixture_bytes: document.bytesize,
  fixture_items: ExternalBridge::RSS::SyntheticFeed::ITEMS,
  gzip_bytes: compressed.bytesize,
  fixture_generate_ms: generate_ms,
  fixture_generate_included_in_fetch: false,
  runs: RUNS,
  note: 'Child RSS is the HTTP.rb client and BodyReader only. The fixture string lives in the parent. 8 MiB is a test profile, not the product default. VmHWM includes client startup; rss_before_kb is after require and GC, before the GET.',
  results: runs,
}

text = JSON.pretty_generate(summary)
path = '/opt/cursor/artifacts/rss_receive_budget_measurement.json'
File.write(path, text)
puts text
exit(runs.all? { |run| run['pass'] } ? 0 : 1)
