# frozen_string_literal: true

require 'rails_helper'
require 'zlib'

# Chunk source for BodyReader. Each readpartial returns at most the requested
# size and leaves the rest queued, so a test can see a later chunk that must
# not be pulled after the cap.
class RssScriptedBody
  attr_reader :reads, :headers, :content_length

  def initialize(chunks, headers: {}, content_length: nil)
    @chunks = chunks.map { |chunk| chunk.dup.b }
    @headers = HTTP::Headers.coerce(headers)
    @content_length = content_length
    @reads = 0
  end

  def readpartial(size = nil)
    @reads += 1
    chunk = @chunks.shift
    return nil if chunk.nil?
    return chunk if size.nil? || chunk.bytesize <= size

    @chunks.unshift(chunk.byteslice(size..-1))
    chunk.byteslice(0, size)
  end

  def remaining_bytes
    @chunks.sum(&:bytesize)
  end
end

RSpec.describe ExternalBridge::RSS::BodyReader do
  def read_body(chunks, received:, inflated:, headers: {}, content_length: nil)
    described_class.read!(
      RssScriptedBody.new(chunks, headers: headers, content_length: content_length),
      received_limit: received,
      inflated_limit: inflated
    )
  end

  def gzip(bytes)
    Zlib.gzip(bytes)
  end

  def raw_deflate(bytes)
    stream = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
    stream.deflate(bytes, Zlib::FINISH)
  ensure
    stream&.close
  end

  it 'accepts each cap exactly and does not read the chunk after the one that crosses it' do
    expect(read_body(['1234567890123456', '7890123456789012'], received: 32, inflated: 32).b).to eq('12345678901234567890123456789012'.b)

    source = RssScriptedBody.new(['1234567890123456', '7890123456789012', 'X', 'AFTER'])
    expect { described_class.read!(source, received_limit: 32, inflated_limit: 32) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(source.remaining_bytes).to eq 'AFTER'.bytesize
  end

  it 'counts UTF-8 as bytes' do
    expect(read_body(['あ'], received: 3, inflated: 3).bytesize).to eq 3
    expect { read_body(['あ'], received: 2, inflated: 2) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(read_body(['あx'], received: 4, inflated: 4).b).to eq "あx".b
    expect { read_body(['ああ'], received: 4, inflated: 4) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end

  it 'treats Content-Length as an early hint and still counts a missing or invalid length' do
    unread = RssScriptedBody.new(['small'], content_length: 33)
    expect { described_class.read!(unread, received_limit: 32, inflated_limit: 10_000) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(unread.reads).to eq 0

    expect(read_body(['12345678901234567890123456789012'], received: 32, inflated: 32, content_length: nil).bytesize).to eq 32
    expect(read_body(['12345678901234567890123456789012'], received: 32, inflated: 32, content_length: 32).bytesize).to eq 32
    expect(read_body(['12345678901234567890123456789012'], received: 32, inflated: 32, content_length: 'nope').bytesize).to eq 32
    expect { read_body(['123456'], received: 32, inflated: 4) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end

  it 'inflates gzip, x-gzip, and zlib-wrapped deflate, including a mixed-case token' do
    plain = 'hello あ'
    %w(gzip x-gzip GZip).each do |encoding|
      body = read_body([gzip(plain)], received: 1_000, inflated: plain.bytesize, headers: { 'Content-Encoding' => encoding })
      expect(body.b).to eq plain.b
    end

    wrapped = Zlib::Deflate.deflate(plain)
    body = read_body([wrapped], received: 1_000, inflated: plain.bytesize, headers: { 'Content-Encoding' => 'deflate' })
    expect(body.b).to eq plain.b
    expect(read_body(['plain-text'], received: 32, inflated: 32, headers: { 'Content-Encoding' => 'identity' }).b).to eq 'plain-text'.b
  end

  it 'fails closed on broken, truncated, raw, compound, and unsupported encodings' do
    cases = [
      ['not-gzip', { 'Content-Encoding' => 'gzip' }],
      [gzip('hello').byteslice(0, 8), { 'Content-Encoding' => 'gzip' }],
      [raw_deflate('hello'), { 'Content-Encoding' => 'deflate' }],
      [gzip('hello'), { 'Content-Encoding' => 'gzip, deflate' }],
      [gzip('hello'), { 'Content-Encoding' => 'br' }],
    ]
    cases.each do |body, headers|
      expect { read_body([body], received: 10_000, inflated: 10_000, headers: headers) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'fetch_failed' }
    end

    rejected = RssScriptedBody.new([gzip('hello')], headers: { 'Content-Encoding' => 'br' })
    expect { described_class.read!(rejected, received_limit: 100, inflated_limit: 100) }
      .to raise_error(ExternalBridge::Error)
    expect(rejected.reads).to eq 0
  end

  it 'lets a small gzip fail the inflated cap and an incompressible gzip fail the received cap' do
    plain = "\0" * 4_000
    compressed = gzip(plain)
    expect(compressed.bytesize).to be < 200
    source = RssScriptedBody.new([compressed, 'NEXT'], headers: { 'Content-Encoding' => 'gzip' })
    expect { described_class.read!(source, received_limit: 1_000, inflated_limit: plain.bytesize - 1) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(source.remaining_bytes).to eq 'NEXT'.bytesize

    noisy = Random.new(1).bytes(300)
    noisy_gzip = gzip(noisy)
    expect(noisy_gzip.bytesize).to be > noisy.bytesize
    expect do
      read_body([noisy_gzip], received: noisy.bytesize, inflated: noisy.bytesize + 50, headers: { 'Content-Encoding' => 'gzip' })
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end

  it 'accepts a carried inflate state that one input slice expands past 1032 times' do
    xml = '<rss version="2.0"><channel><title>Example</title>' \
          '<link>https://news.example/</link><description>News</description>' \
          '<item><guid>entry-1</guid><title>Entry 1</title>' \
          '<link>https://news.example/1</link><description>' +
          ('a' * 3_900_000) +
          '</description></item></channel></rss>'
    compressed = Zlib.gzip(xml, level: 6)
    expect(xml.bytesize).to be < 4.megabytes
    expect(compressed.bytesize).to be < 4.megabytes

    yields = []
    inflater = Zlib::Inflate.new(described_class::WINDOW_BITS)
    inflater.inflate(compressed) { |chunk| yields << chunk.bytesize }
    inflater.close
    expect(yields.max).to be <= described_class::INFLATE_YIELD_MAX
    expect(yields.max).to eq described_class::INFLATE_YIELD_MAX

    [1, 6, 7, 64, 1024].each do |lead|
      source = RssScriptedBody.new(
        [compressed.byteslice(0, lead), compressed.byteslice(lead..-1)],
        headers: { 'Content-Encoding' => 'gzip' }
      )
      body = described_class.read!(source, received_limit: 4.megabytes, inflated_limit: 4.megabytes)
      expect(body.b).to eq(xml.b), "lead #{lead}"
    end
  end

  it 'closes the inflater when inflate succeeds, fails, or passes the cap' do
    plain = "\0" * 80_000
    compressed = gzip(plain)
    closed = 0
    allow(Zlib::Inflate).to receive(:new).and_wrap_original do |original, *args|
      stream = original.call(*args)
      allow(stream).to receive(:close).and_wrap_original do |close, *close_args|
        closed += 1
        close.call(*close_args)
      end
      stream
    end

    read_body([gzip('ok')], received: 100, inflated: 100, headers: { 'Content-Encoding' => 'gzip' })
    expect { read_body([gzip('hello').byteslice(0, 6)], received: 100, inflated: 100, headers: { 'Content-Encoding' => 'gzip' }) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'fetch_failed' }
    expect { read_body([compressed], received: compressed.bytesize, inflated: 100, headers: { 'Content-Encoding' => 'gzip' }) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(closed).to eq 3
  end
end

RSpec.describe ExternalBridge::RSS::HttpClient do
  before do
    redis.keys('external_bridge:rss*:host:*').each { |key| redis.del(key) }
  end

  def feed_limits(received:, inflated:)
    described_class::FEED_PROFILE.dup.tap do |profile|
      profile.max_received_bytes = received
      profile.max_inflated_bytes = inflated
      profile.max_bytes = inflated
    end
  end

  def gzip(bytes)
    Zlib.gzip(bytes)
  end

  it 'keeps the public 4 MiB caps and leaves the other profiles on their own limits' do
    limits = ExternalBridge::RSS::Limits
    expect(limits::MAX_RESPONSE_BYTES).to eq 4.megabytes
    expect(limits::MAX_RECEIVED_BYTES).to eq 4.megabytes
    expect(described_class::FEED_PROFILE.max_received_bytes).to eq 4.megabytes
    expect(described_class::FEED_PROFILE.max_inflated_bytes).to eq 4.megabytes
    expect(described_class::NODEINFO_PROFILE.max_bytes).to eq 64.kilobytes
    expect(described_class::ACTIVITYPUB_PROFILE.max_bytes).to eq 256.kilobytes
    expect(described_class::ICON_IMAGE_PROFILE.max_bytes).to eq limits::ICON_MAX_BYTES
    expect(described_class::ICON_PAGE_PROFILE.max_bytes).to eq limits::ICON_MAX_PAGE_BYTES
    expect(described_class::ICON_PAGE_PROFILE.truncate).to be true
    expect(described_class::MEDIA_IMAGE_PROFILE.max_bytes).to eq limits::MEDIA_IMAGE_MAX_BYTES
    expect(described_class::REDIRECT_HOPS).to eq 3
  end

  it 'inflates gzip through the HTTP client and does not enable auto_inflate' do
    plain = '<rss><channel><title>Hi あ</title></channel></rss>'
    clients = []
    allow(HTTP::Client).to receive(:new).and_wrap_original do |original, *args|
      client = original.call(*args)
      clients << client
      client
    end
    stub_request(:get, 'https://feeds.example/news.xml').to_return(
      status: 200,
      body: gzip(plain),
      headers: { 'Content-Encoding' => 'gzip', 'Content-Type' => 'application/rss+xml' }
    )

    response = described_class.get('https://feeds.example/news.xml')

    expect(response.body.b).to eq plain.b
    expect(clients).to all(satisfy { |client| !client.default_options.features.key?(:auto_inflate) })
  end

  it 'closes the client without Body#to_s when the feed cap is crossed' do
    stub_request(:get, 'https://feeds.example/news.xml').to_return(status: 200, body: 'x' * 40)
    closes = 0
    allow(HTTP::Client).to receive(:new).and_wrap_original do |original, *args|
      client = original.call(*args)
      allow(client).to receive(:close).and_wrap_original do |close, *close_args|
        closes += 1
        close.call(*close_args)
      end
      client
    end
    expect_any_instance_of(HTTP::Response::Body).not_to receive(:to_s)

    expect { described_class.get('https://feeds.example/news.xml', profile: feed_limits(received: 8, inflated: 8)) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(closes).to be >= 1
  end

  it 'sends an ASCII Host for an IDN on the first hop and after a redirect' do
    plain = 'https://例え.テスト/feed.xml'
    ported = 'https://例え.テスト:8443/feed.xml'
    ascii_host = 'xn--r8jz45g.xn--zckzah'
    stub_request(:get, plain).to_return(status: 200, body: '<rss/>')
    stub_request(:head, plain).to_return(status: 200, headers: { 'Content-Length' => '0' })
    stub_request(:get, ported).to_return(status: 200, body: '<rss/>')
    stub_request(:head, ported).to_return(status: 200, headers: { 'Content-Length' => '0' })

    expect(described_class.get(plain).body).to eq '<rss/>'
    expect(described_class.head(plain).code).to eq 200
    expect(described_class.get(ported).body).to eq '<rss/>'
    expect(described_class.head(ported).code).to eq 200

    {
      'https://feeds.example/to-idn.xml' => plain,
      'https://feeds.example/to-idn-port.xml' => ported,
    }.each do |start, location|
      stub_request(:get, start).to_return(status: 302, headers: { 'Location' => location })
      stub_request(:head, start).to_return(status: 302, headers: { 'Location' => location })
      expect(described_class.get(start).body).to eq '<rss/>'
      expect(described_class.head(start).code).to eq 200
      expect(a_request(:get, start).with(headers: { 'Host' => 'feeds.example' })).to have_been_made
      expect(a_request(:head, start).with(headers: { 'Host' => 'feeds.example' })).to have_been_made
    end

    ascii_url = "https://#{ascii_host}/feed.xml"
    ascii_ported = "https://#{ascii_host}:8443/feed.xml"
    expect(a_request(:get, ascii_url).with(headers: { 'Host' => ascii_host })).to have_been_made.twice
    expect(a_request(:head, ascii_url).with(headers: { 'Host' => ascii_host })).to have_been_made.twice
    expect(a_request(:get, ascii_ported).with(headers: { 'Host' => "#{ascii_host}:8443" })).to have_been_made.twice
    expect(a_request(:head, ascii_ported).with(headers: { 'Host' => "#{ascii_host}:8443" })).to have_been_made.twice
  end

  it 'keeps brackets around an IPv6 literal in Host' do
    literal = 'https://[2606:4700:4700::1111]/feed.xml'
    ported = 'https://[2606:4700:4700::1111]:8443/feed.xml'
    stub_request(:get, literal).to_return(status: 200, body: '<rss/>')
    stub_request(:head, literal).to_return(status: 200, headers: { 'Content-Length' => '0' })
    stub_request(:get, ported).to_return(status: 200, body: '<rss/>')
    stub_request(:head, ported).to_return(status: 200, headers: { 'Content-Length' => '0' })

    expect(described_class.get(literal).body).to eq '<rss/>'
    expect(described_class.head(literal).code).to eq 200
    expect(described_class.get(ported).body).to eq '<rss/>'
    expect(described_class.head(ported).code).to eq 200
    expect(a_request(:get, literal).with(headers: { 'Host' => '[2606:4700:4700::1111]' })).to have_been_made
    expect(a_request(:head, literal).with(headers: { 'Host' => '[2606:4700:4700::1111]' })).to have_been_made
    expect(a_request(:get, ported).with(headers: { 'Host' => '[2606:4700:4700::1111]:8443' })).to have_been_made
    expect(a_request(:head, ported).with(headers: { 'Host' => '[2606:4700:4700::1111]:8443' })).to have_been_made
  end

  it 'sends Host without a default port and keeps a non-default port after redirect' do
    start = 'https://feeds.example/start.xml'
    redirected = 'https://feeds.example:8443/feed.xml'
    stub_request(:get, start).to_return(status: 302, headers: { 'Location' => redirected })
    stub_request(:get, redirected).to_return(status: 200, body: '<rss/>')
    stub_request(:head, start).to_return(status: 302, headers: { 'Location' => redirected })
    stub_request(:head, redirected).to_return(status: 200, headers: { 'Content-Length' => '4' })

    expect(described_class.get(start).body).to eq '<rss/>'
    expect(described_class.head(start).code).to eq 200
    %i(get head).each do |verb|
      expect(a_request(verb, start).with(headers: { 'Host' => 'feeds.example' })).to have_been_made
      expect(a_request(verb, redirected).with(headers: { 'Host' => 'feeds.example:8443' })).to have_been_made
    end
  end

  it 'follows a relative redirect, repeats validators, and stops after three hops' do
    start = 'https://feeds.example/dir/start.xml'
    final_url = 'https://feeds.example/dir/next.xml'
    stub_request(:get, start).to_return(status: 302, headers: { 'Location' => 'next.xml' })
    stub_request(:get, final_url).to_return(status: 200, body: '<rss/>')

    response = described_class.get(start, etag: 'W/"one"', last_modified: 'Thu, 02 Jan 2020 03:04:05 GMT')

    expect(response.body).to eq '<rss/>'
    expect(response.final_url).to eq final_url
    expect(a_request(:get, final_url).with(headers: {
      'If-None-Match' => 'W/"one"',
      'If-Modified-Since' => 'Thu, 02 Jan 2020 03:04:05 GMT',
    })).to have_been_made
    expect(redis.get('external_bridge:rss:host:feeds.example').to_i).to eq 2

    chain = %w(
      https://feeds.example/hop.xml
      https://feeds.example/1.xml
      https://feeds.example/2.xml
      https://feeds.example/3.xml
      https://feeds.example/4.xml
    )
    chain.each_cons(2) { |from, to| stub_request(:get, from).to_return(status: 302, headers: { 'Location' => to }) }
    stub_request(:get, chain.last).to_return(status: 200, body: '<rss/>')
    expect { described_class.get(chain.first) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'too_many_redirects' }
    expect(a_request(:get, chain.last)).not_to have_been_made
  end

  it 'rejects a private or credential redirect before the next request' do
    stub_request(:get, 'https://feeds.example/bounce.xml').to_return(status: 302, headers: { 'Location' => 'http://127.0.0.1/secret.xml' })
    stub_request(:get, 'http://127.0.0.1/secret.xml').to_return(status: 200, body: '<rss/>')
    stub_request(:get, 'https://feeds.example/token.xml').to_return(status: 302, headers: { 'Location' => 'https://feeds.example/hidden.xml?token=SECRET' })

    expect { described_class.get('https://feeds.example/bounce.xml') }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'private_address' }
    expect { described_class.get('https://feeds.example/token.xml') }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'authenticated_source_rejected' }
    expect(a_request(:get, 'http://127.0.0.1/secret.xml')).not_to have_been_made
    expect(a_request(:get, /hidden\.xml/)).not_to have_been_made
  end

  it 'returns 304 without replacing the body and then rate-limits the host' do
    url = 'https://feeds.example/news.xml'
    stub_request(:get, url).to_return(status: 304, headers: { 'ETag' => 'W/"ignored"' })

    response = described_class.get(url, etag: 'W/"one"')
    expect(response.code).to eq 304
    expect(response.body).to be_nil

    (ExternalBridge::RSS::Limits::HOST_BUDGET - 1).times { described_class.get(url, etag: 'W/"one"') }
    expect { described_class.get(url, etag: 'W/"one"') }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'rate_limited' }
  end

  it 'does not use the feed reader for NodeInfo, a larger image, or a truncated icon page' do
    nodeinfo = 'https://feeds.example/.well-known/nodeinfo'
    image = 'https://cdn.example/photo.jpg'
    page = 'https://news.example/about'
    expect(ExternalBridge::RSS::BodyReader).not_to receive(:read!)

    stub_request(:get, nodeinfo).to_return(status: 200, body: 'x' * 100.kilobytes, headers: { 'Content-Type' => 'application/json' })
    expect do
      described_class.get(nodeinfo, profile: described_class::NODEINFO_PROFILE, origin: 'https://feeds.example')
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }

    stub_request(:get, image).to_return(status: 200, body: 'x' * (4.megabytes + 10), headers: { 'Content-Type' => 'image/jpeg' })
    expect(described_class.get(image, profile: described_class::MEDIA_IMAGE_PROFILE).body.bytesize).to eq(4.megabytes + 10)

    stub_request(:get, page).to_return(
      status: 200,
      body: 'a' * (ExternalBridge::RSS::Limits::ICON_MAX_PAGE_BYTES + 30),
      headers: { 'Content-Type' => 'text/html' }
    )
    expect(described_class.get(page, profile: described_class::ICON_PAGE_PROFILE).body.bytesize).to eq ExternalBridge::RSS::Limits::ICON_MAX_PAGE_BYTES
  end

  it 'records the non-default Host on the redirect target that actually received the request' do
    with_local_feed do |server, url, port|
      %i(get head).each do |verb|
        seen = Queue.new
        server_thread(server) do |redirect|
          seen << request_host(read_http_request(redirect))
          redirect.write("HTTP/1.1 302 Found\r\nLocation: http://feeds.example:#{port}/final.xml\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          redirect.close
          final = server.accept
          seen << request_host(read_http_request(final))
          if verb == :head
            final.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          else
            final.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
          end
          final.close
        end
        result = described_class.public_send(verb, url)
        expect(seen.pop(timeout: 2)).to eq "feeds.example:#{port}"
        expect(seen.pop(timeout: 2)).to eq "feeds.example:#{port}"
        expect(result.body).to eq(verb == :head ? nil : 'hello')
      end
    end
  end

  it 'reads real chunked bodies, stops when the cap is crossed, and does not wait on a redirect body' do
    with_local_feed do |server, url, port|
      server_thread(server) do |client|
        read_http_request(client)
        client.write(chunked_headers)
        %w(12345678 90).each { |chunk| client.write(chunk_frame(chunk)) }
        client.write("0\r\n\r\n")
        client.close
      end
      expect(described_class.get(url, profile: feed_limits(received: 10, inflated: 10)).body.b).to eq '1234567890'.b

      saw_close = Queue.new
      server_thread(server) do |client|
        read_http_request(client)
        client.write(chunked_headers + chunk_frame('x' * 11))
        client.flush
        saw_close << (IO.select([client], nil, nil, 2) && client.eof?)
      end
      expect { described_class.get(url, profile: feed_limits(received: 8, inflated: 8)) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
      expect(saw_close.pop(timeout: 3)).to be true

      server_thread(server) do |redirect|
        read_http_request(redirect)
        redirect.write("HTTP/1.1 302 Found\r\nLocation: http://feeds.example:#{port}/final.xml\r\nContent-Length: 8000000\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n")
        redirect.flush
        final = server.accept
        read_http_request(final)
        final.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        final.close
      end
      expect(Timeout.timeout(3) { described_class.get(url).body }).to eq 'hello'
    end
  end

  it 'inflates chunked gzip and does not treat a short Content-Length as unread extra bytes' do
    plain = '<rss>hello あ</rss>'
    with_local_feed do |server, url, _port|
      compressed = gzip(plain)
      server_thread(server) do |client|
        read_http_request(client)
        client.write(chunked_headers('Content-Encoding' => 'gzip'))
        offset = 0
        while offset < compressed.bytesize
          piece = compressed.byteslice(offset, 5)
          offset += piece.bytesize
          client.write(chunk_frame(piece))
        end
        client.write("0\r\n\r\n")
        client.close
      end
      expect(described_class.get(url).body.b).to eq plain.b

      server_thread(server) do |client|
        read_http_request(client)
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcdNOT-DELIVERED")
        client.close
      end
      expect(described_class.get(url).body).to eq 'abcd'

      server_thread(server) do |client|
        read_http_request(client)
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 50\r\nConnection: close\r\n\r\n")
        client.flush
      end
      expect do
        Timeout.timeout(3) { described_class.get(url, profile: feed_limits(received: 8, inflated: 8)) }
      end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    end
  end

  it 'rejects the synthetic document at 4 MiB and accepts it only on an explicit larger profile' do
    document = ExternalBridge::RSS::SyntheticFeed.generate
    expect(document.bytesize).to eq ExternalBridge::RSS::SyntheticFeed::TARGET_BYTES
    expect(document.scan('<item>').size).to eq ExternalBridge::RSS::SyntheticFeed::ITEMS
    expect(document.scan('<![CDATA[').size).to eq ExternalBridge::RSS::SyntheticFeed::ITEMS
    expect(document.scan(']]>').size).to eq ExternalBridge::RSS::SyntheticFeed::ITEMS
    expect(document).not_to include('<!--')
    strict = Nokogiri::XML(document) { |config| config.strict.nonet }
    expect(strict.xpath('/rss/channel/item').size).to eq ExternalBridge::RSS::SyntheticFeed::ITEMS
    expect { ExternalBridge::RSS::Parser.parse!(document) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    wide = ExternalBridge::RSS::DocumentBudget::Budget.default
    wide.max_bytes = 8.megabytes
    wide.max_text_bytes = 8.megabytes
    expect(ExternalBridge::RSS::Parser.parse!(document, budget: wide).items.size).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
    expect(document.scan(%r{https://media\.example/audio/\d+\.mp3}).uniq.size).to eq ExternalBridge::RSS::SyntheticFeed::ITEMS
    expect(document.scan(%r{https://media\.example/images/\d+\.jpg}).uniq.size).to eq ExternalBridge::RSS::SyntheticFeed::ITEMS

    chunks = []
    offset = 0
    while offset < document.bytesize
      chunks << document.byteslice(offset, 1024)
      offset += 1024
    end
    source = RssScriptedBody.new(chunks)
    expect do
      ExternalBridge::RSS::BodyReader.read!(
        source,
        received_limit: ExternalBridge::RSS::Limits::MAX_RECEIVED_BYTES,
        inflated_limit: ExternalBridge::RSS::Limits::MAX_RESPONSE_BYTES
      )
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(source.remaining_bytes).to be > 1.megabyte

    accepted = ExternalBridge::RSS::BodyReader.read!(
      RssScriptedBody.new([document]),
      received_limit: 8.megabytes,
      inflated_limit: 8.megabytes
    )
    expect(accepted.bytesize).to eq document.bytesize

    compressed = gzip(document)
    expect(compressed.bytesize).to be < 4.megabytes
    expect do
      ExternalBridge::RSS::BodyReader.read!(
        RssScriptedBody.new([compressed], headers: { 'Content-Encoding' => 'gzip' }),
        received_limit: 4.megabytes,
        inflated_limit: 4.megabytes
      )
    end.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }

    url = 'https://feeds.example/synthetic.xml'
    stub_request(:get, url).to_return(status: 200, body: document, headers: { 'Content-Type' => 'application/rss+xml' })
    expect(ExternalBridge::RSS::Parser).not_to receive(:parse!)
    expect { described_class.get(url) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
    expect(described_class.get(url, profile: feed_limits(received: 8.megabytes, inflated: 8.megabytes)).body.bytesize).to eq document.bytesize
  end

  def with_local_feed
    WebMock.disable!
    server = TCPServer.new('127.0.0.1', 0)
    @server_threads = []
    port = server.addr[1]
    allow(Request.send(:const_get, :Socket)).to receive(:check_private_address)
    resolver = instance_double(Resolv::DNS)
    allow(Resolv::DNS).to receive(:open).and_yield(resolver)
    allow(resolver).to receive(:timeouts=)
    allow(resolver).to receive(:getaddresses).and_return([Resolv::IPv4.create('127.0.0.1')])
    yield server, "http://feeds.example:#{port}/feed.xml", port
  ensure
    server&.close
    @server_threads&.each { |thread| thread.join(1) }
    WebMock.enable!
  end

  def server_thread(server)
    @server_threads << Thread.new do
      client = server.accept
      yield client
    rescue IOError, Errno::EBADF, Errno::ECONNRESET, Errno::EPIPE
      nil
    end
  end

  def chunked_headers(extra = {})
    headers = { 'Transfer-Encoding' => 'chunked', 'Connection' => 'close', 'Content-Type' => 'application/xml' }.merge(extra)
    "HTTP/1.1 200 OK\r\n#{headers.map { |name, value| "#{name}: #{value}" }.join("\r\n")}\r\n\r\n"
  end

  def chunk_frame(bytes)
    "#{bytes.bytesize.to_s(16)}\r\n#{bytes}\r\n"
  end

  def read_http_request(io)
    buffer = +''
    buffer << io.readpartial(1024) while buffer.exclude?("\r\n\r\n") && buffer.bytesize < 65_536
    buffer
  end

  def request_host(raw)
    raw[/^Host:\s*(\S+)/i, 1]
  end
end

RSpec.describe 'RSS feed cap failures' do
  let(:user) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/news.xml' }

  before do
    enable_external_bridge_rss!(user)
    redis.keys('external_bridge:rss*:host:*').each { |key| redis.del(key) }
  end

  it 'does not store a source, resource, or projection when the first fetch is too large' do
    stub_request(:get, feed_url).to_return(status: 200, body: 'x' * (4.megabytes + 1))
    expect(ExternalBridge::RSS::Parser).not_to receive(:parse!)

    expect { ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }

    expect(ExternalSource.where(canonical_key: feed_url)).to be_empty
    expect(ExternalResource.count).to eq 0
    expect(ExternalSubscription.count).to eq 0
    expect(ExternalStatusProjection.count).to eq 0
  end

  it 'keeps the stored feed and schedules a retry when a later fetch is too large' do
    stub_request(:get, feed_url).to_return(
      status: 200,
      body: rss_document(rss_item(guid: 'guid-1', body: 'Public copy')),
      headers: { 'ETag' => 'W/"one"', 'Last-Modified' => 'Thu, 02 Jan 2020 03:04:05 GMT' }
    )
    ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    source = ExternalSource.find_by!(canonical_key: feed_url)
    source.update!(fetched_at: 1.hour.ago)
    before_row = source.reload.attributes.slice('etag', 'title', 'fetched_at', 'last_modified', 'canonical_key')
    resource = source.external_resources.first
    projection = ExternalStatusProjection.find_by!(user_id: user.id, external_resource_id: resource.id)
    ExternalSubscription.where(external_source_id: source.id).update_all(checked_at: 2.hours.ago)
    lines = []
    allow(Rails.logger).to receive(:info) { |message| lines << message.to_s }

    stub_request(:get, feed_url).to_return(status: 200, body: 'x' * (4.megabytes + 1), headers: { 'ETag' => 'W/"huge"' })
    ExternalBridge::RSS::RefreshSourceWorker.new.perform(source.id)

    expect(source.reload.attributes.slice(*before_row.keys)).to eq before_row
    expect(resource.reload.body).to eq 'Public copy'
    expect(ExternalStatusProjection.find(projection.id).status_id).to eq projection.status_id
    subscription = ExternalSubscription.find_by!(user: user, external_source: source)
    expect(subscription.last_error_code).to eq 'oversized_feed'
    expect(subscription.retry_count).to eq 1
    expect(subscription.next_retry_at).to be_present
    expect(subscription.state).to eq 'active'
    logged = lines.find { |line| line.include?('error_code=oversized_feed') }
    expect(logged).to be_present
    expect(logged).not_to include(feed_url)
    expect(logged).not_to include('xxxx')
  end
end
