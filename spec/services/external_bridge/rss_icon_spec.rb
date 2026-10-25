# frozen_string_literal: true

# The examples share one fixture matrix.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Icon::RefreshSource do
  subject(:refresh) { described_class.new }

  let(:feed_url) { 'https://example.com/feed.xml' }
  let(:icon_url) { 'https://cdn.example/icon.png' }

  before do
    Setting.external_bridge_rss = true
    redis.keys('external_bridge:rss_icon:host:*').each { |key| redis.del(key) }
  end

  def stored(source)
    source.reload
    expect(source.icon).to be_present
    source
  end

  def feed_xml(channel_extra)
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Example feed</title><link>https://example.com</link>#{channel_extra}</channel></rss>
    XML
  end

  describe 'parsing the feed-declared candidates' do
    it 'reads the RSS 2.0 channel image' do
      feed = ExternalBridge::RSS::Parser.parse!(feed_xml('<image><url>https://cdn.example/rss.png</url><title>t</title><link>https://example.com</link></image>'))
      expect(feed.icon_hints).to eq [{ 'kind' => 'rss_image', 'url' => 'https://cdn.example/rss.png' }]
    end

    it 'reads Atom icon before logo and ignores per-entry images' do
      atom = <<~XML
        <feed xmlns="http://www.w3.org/2005/Atom"><title>A</title><link href="https://example.com/"/>
          <logo>https://cdn.example/logo.png</logo><icon>/icon.png</icon>
          <entry><id>1</id><title>e</title><icon>https://evil.example/entry.png</icon></entry>
        </feed>
      XML
      feed = ExternalBridge::RSS::Parser.parse!(atom)
      expect(feed.icon_hints.map { |hint| hint['kind'] }).to eq %w(atom_icon atom_logo)
      expect(feed.icon_hints.first['url']).to eq '/icon.png'
    end

    it 'does not treat the iTunes cover art as a site icon' do
      xml = feed_xml('<itunes:image xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" href="https://cdn.example/cover.jpg"/>')
      expect(ExternalBridge::RSS::Parser.parse!(xml).icon_hints).to eq []
    end
  end

  describe 'discovery order' do
    it 'stores the Atom icon declared by the feed' do
      source = icon_source(hints: [declared('atom_icon', icon_url)])
      icon_subscriber(source)
      stub_icon(icon_url)

      expect(refresh.call(source.id)).to eq 'icon_stored'

      stored(source)
      expect(source.icon_remote_url).to eq icon_url
      expect(source.icon_origin).to eq 'atom_icon'
      expect(source.icon_fingerprint).to eq Digest::SHA256.hexdigest(icon_image)
      expect(source.icon_content_type).to eq 'image/webp'
      expect(source.icon.path(:original)).to end_with('.webp')
      expect(source.icon_failure_count).to eq 0
      expect(source.icon_next_check_at).to be > 6.days.from_now
      expect(File.exist?(source.icon.path(:original))).to be true
    end

    it 'stores the RSS 2.0 channel image and resolves a relative URL against the feed' do
      source = icon_source(hints: [declared('rss_image', '/img/rss.png')])
      icon_subscriber(source)
      stub_icon('https://example.com/img/rss.png')

      expect(refresh.call(source.id)).to eq 'icon_stored'
      expect(source.reload.icon_remote_url).to eq 'https://example.com/img/rss.png'
      expect(source.icon_origin).to eq 'rss_image'
    end

    it 'skips a banner-shaped Atom logo and falls through to the page icon' do
      source = icon_source(hints: [declared('atom_logo', 'https://cdn.example/banner.png')])
      icon_subscriber(source)
      stub_icon('https://cdn.example/banner.png', bytes: icon_image('png', 400, 100))
      stub_request(:get, 'https://example.com').to_return(
        status: 200, headers: { 'Content-Type' => 'text/html' },
        body: '<html><head><link rel="icon" href="/site.png"></head></html>'
      )
      stub_icon('https://example.com/site.png')

      expect(refresh.call(source.id)).to eq 'icon_stored'
      expect(source.reload.icon_origin).to eq 'html_icon'
    end

    it 'prefers the larger declared HTML icon and resolves relative URLs against the page' do
      source = icon_source(site_url: 'https://example.com/blog/')
      icon_subscriber(source)
      stub_request(:get, 'https://example.com/blog/').to_return(
        status: 200, headers: { 'Content-Type' => 'text/html; charset=utf-8' },
        body: <<~HTML
          <html><head><base href="https://elsewhere.example/">
          <link rel="shortcut icon" sizes="16x16" href="small.png">
          <link rel="icon" sizes="64x64" href="../big.png">
          <link rel="mask-icon" href="mask.svg"><link rel="icon" type="image/svg+xml" href="vector.svg">
          </head></html>
        HTML
      )
      stub_icon('https://example.com/big.png')
      stub_icon('https://example.com/blog/small.png')

      expect(refresh.call(source.id)).to eq 'icon_stored'
      expect(source.reload.icon_remote_url).to eq 'https://example.com/big.png'
      expect(a_request(:get, 'https://example.com/blog/small.png')).not_to have_been_made
    end

    it 'falls back to /favicon.ico of the site and accepts an ICO' do
      source = icon_source
      icon_subscriber(source)
      stub_request(:get, 'https://example.com').to_return(status: 404, body: 'no')
      stub_icon('https://example.com/favicon.ico', bytes: icon_image('ico', 32), type: 'image/x-icon')

      expect(refresh.call(source.id)).to eq 'icon_stored'
      expect(source.reload.icon_origin).to eq 'favicon'
      expect(source.icon_content_type).to eq 'image/vnd.microsoft.icon'
      expect(File.binread(source.icon.path(:original))).to eq icon_image('ico', 32)
    end

    it 'does not borrow the favicon of an unrelated site named by the feed' do
      source = icon_source(site_url: 'https://other-brand.example', canonical_key: 'https://feeds.example/news.xml')
      icon_subscriber(source)
      stub_request(:get, 'https://feeds.example').to_return(status: 404, body: 'no')
      stub_request(:get, 'https://feeds.example/favicon.ico').to_return(status: 404, body: 'no')

      expect(refresh.call(source.id)).to eq 'icon_failed'
      expect(a_request(:get, /other-brand\.example/)).not_to have_been_made
      expect(a_request(:get, 'https://feeds.example/favicon.ico')).to have_been_made.once
    end

    it 'records failure with a backoff when nothing is found and keeps no icon' do
      source = icon_source
      icon_subscriber(source)
      stub_request(:get, 'https://example.com').to_return(status: 404, body: 'no')
      stub_request(:get, 'https://example.com/favicon.ico').to_return(status: 404, body: 'no')

      expect(refresh.call(source.id)).to eq 'icon_failed'

      source.reload
      expect(source.icon).not_to be_present
      expect(source.icon_failure_count).to eq 1
      expect(source.icon_error_code).to eq 'http_404'
      expect(source.icon_next_check_at).to be_between(50.minutes.from_now, 70.minutes.from_now)
      expect(ExternalBridge::RSS::Icon::Delivery.url(source)).to be_nil
    end

    it 'reads the feed once for a source that predates the icon feature' do
      source = icon_source(hints: nil)
      icon_subscriber(source)
      stub_request(:get, feed_url).to_return(
        status: 200, headers: { 'Content-Type' => 'application/rss+xml' },
        body: feed_xml('<image><url>https://cdn.example/rss.png</url></image>')
      )
      stub_icon('https://cdn.example/rss.png')

      expect(refresh.call(source.id)).to eq 'icon_stored'

      source.reload
      expect(source.icon_hints).to eq [declared('rss_image', 'https://cdn.example/rss.png')]
      expect(source.icon_origin).to eq 'rss_image'
    end

    it 'persists the hints read from the feed together with a failed outcome' do
      source = icon_source(hints: nil)
      icon_subscriber(source)
      stub_request(:get, feed_url).to_return(
        status: 200, headers: { 'Content-Type' => 'application/rss+xml' },
        body: feed_xml('<image><url>https://cdn.example/rss.png</url></image>')
      )
      stub_request(:get, 'https://cdn.example/rss.png').to_return(status: 404, body: 'no')
      stub_request(:get, 'https://example.com').to_return(status: 404, body: 'no')
      stub_request(:get, 'https://example.com/favicon.ico').to_return(status: 404, body: 'no')

      expect(refresh.call(source.id)).to eq 'icon_failed'

      expect(source.reload.icon_hints).to eq [declared('rss_image', 'https://cdn.example/rss.png')]
    end

    it 'does not write the source row until the downloads are finished' do
      source = icon_source(hints: nil)
      icon_subscriber(source)
      stub_request(:get, feed_url).to_return(
        status: 200, headers: { 'Content-Type' => 'application/rss+xml' },
        body: feed_xml('<image><url>https://cdn.example/rss.png</url></image>')
      )
      seen = nil
      stub_request(:get, 'https://cdn.example/rss.png').to_return do
        seen = ExternalSource.where(id: source.id).pick(:icon_hints)
        { status: 200, body: icon_image, headers: { 'Content-Type' => 'image/png' } }
      end

      expect(refresh.call(source.id)).to eq 'icon_stored'
      expect(seen).to be_nil
    end

    it 'stops trying candidates once the run deadline has passed' do
      stub_const('ExternalBridge::RSS::Limits::ICON_RUN_DEADLINE', -1)
      source = icon_source(hints: [declared('atom_icon', icon_url)])
      icon_subscriber(source)
      stub_icon(icon_url)

      expect(refresh.call(source.id)).to eq 'icon_failed'

      expect(a_request(:get, icon_url)).not_to have_been_made
      source = source.reload
      expect(source.icon_error_code).to eq 'icon_deadline'
      expect(source.icon_next_check_at).to be > 30.minutes.from_now
    end

    it 'queries are limited to harmless cache-busting names' do
      source = icon_source(hints: [declared('atom_icon', 'https://cdn.example/icon.png?v=3'), declared('rss_image', 'https://cdn.example/other.png?token=abc')])
      icon_subscriber(source)
      stub_icon('https://cdn.example/icon.png?v=3')

      expect(refresh.call(source.id)).to eq 'icon_stored'
      expect(a_request(:get, /token=abc/)).not_to have_been_made
    end
  end

  describe 'fail-closed handling' do
    let(:fetch) { ExternalBridge::RSS::Icon::ImageFetch.new }

    def expect_fetch_error(code, url = icon_url)
      expect { fetch.call(url) }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq code }
    end

    it 'rejects SVG whatever it claims to be' do
      svg = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><script>alert(1)</script></svg>'
      stub_icon(icon_url, bytes: svg, type: 'image/svg+xml')
      expect_fetch_error 'icon_bad_content_type'
      stub_icon(icon_url, bytes: svg, type: 'image/png')
      expect_fetch_error 'icon_unrecognized_image'
    end

    it 'rejects an image served with a mismatching Content-Type' do
      stub_icon(icon_url, bytes: icon_image('png'), type: 'image/jpeg')
      expect_fetch_error 'icon_type_mismatch'
    end

    it 'rejects a non-image Content-Type even when the bytes are a PNG' do
      stub_icon(icon_url, bytes: icon_image('png'), type: 'text/html')
      expect_fetch_error 'icon_bad_content_type'
    end

    it 'rejects a corrupt image and HTML masquerading as one' do
      stub_icon(icon_url, bytes: "\x89PNG\r\n\x1a\nnot really".b)
      expect_fetch_error 'icon_unrecognized_image'
      stub_icon(icon_url, bytes: '<html>hello</html>')
      expect_fetch_error 'icon_unrecognized_image'
    end

    it 'rejects an empty body' do
      stub_icon(icon_url, bytes: '')
      expect_fetch_error 'icon_empty'
    end

    it 'rejects an oversized response' do
      stub_icon(icon_url, bytes: 'x' * (ExternalBridge::RSS::Limits::ICON_MAX_BYTES + 1))
      expect_fetch_error 'oversized_feed'
    end

    it 'rejects a one pixel tracking image' do
      stub_icon(icon_url, bytes: icon_image('png', 1))
      expect_fetch_error 'icon_too_small'
    end

    it 'rejects a banner' do
      stub_icon(icon_url, bytes: icon_image('png', 300, 10))
      expect_fetch_error 'icon_too_small'
      stub_icon(icon_url, bytes: icon_image('png', 300, 100))
      expect_fetch_error 'icon_unsuitable_shape'
    end

    it 'rejects excessive dimensions and pixel counts' do
      stub_icon(icon_url, bytes: icon_image('png', ExternalBridge::RSS::Limits::ICON_MAX_DIMENSION + 1, 20))
      expect_fetch_error 'icon_dimensions'
      stub_icon(icon_url, bytes: icon_image('png', 2100, 2100))
      expect_fetch_error 'icon_dimensions'
    end

    it 'treats a timeout and a server error as failures' do
      stub_request(:get, icon_url).to_timeout
      expect_fetch_error 'fetch_failed'
      stub_request(:get, icon_url).to_return(status: 503, body: 'down')
      expect_fetch_error 'http_503'
    end

    it 'does not request a private literal address' do
      expect_fetch_error 'private_address', 'http://127.0.0.1/icon.png'
      expect_fetch_error 'private_address', 'http://169.254.169.254/latest/icon.png'
      expect_fetch_error 'private_address', 'http://[::1]/icon.png'
      expect(a_request(:get, /127\.0\.0\.1|169\.254|::1/)).not_to have_been_made
    end

    it 'does not follow a redirect onto a private address' do
      stub_request(:get, icon_url).to_return(status: 302, headers: { 'Location' => 'http://169.254.169.254/icon.png' })
      stub_icon('http://169.254.169.254/icon.png')

      expect_fetch_error 'private_address'
      expect(a_request(:get, 'http://169.254.169.254/icon.png')).not_to have_been_made
    end

    it 'does not follow a redirect to a credential URL or a token query' do
      stub_request(:get, icon_url).to_return(status: 302, headers: { 'Location' => 'https://user:pass@cdn.example/icon.png' })
      expect_fetch_error 'authenticated_source_rejected'
      stub_request(:get, icon_url).to_return(status: 302, headers: { 'Location' => 'https://cdn.example/icon.png?access_token=abc' })
      expect_fetch_error 'authenticated_source_rejected'
    end

    it 'rejects userinfo and token URLs without a request' do
      expect_fetch_error 'authenticated_source_rejected', 'https://user:pw@cdn.example/icon.png'
      expect_fetch_error 'authenticated_source_rejected', 'https://cdn.example/icon.png?access_token=x'
      expect_fetch_error 'unsupported_url', 'ftp://cdn.example/icon.png'
      expect_fetch_error 'unsupported_url', 'data:image/png;base64,AAAA'
      expect(a_request(:get, /cdn\.example/)).not_to have_been_made
    end

    it 'does not follow more than three redirects' do
      stub_request(:get, icon_url).to_return(status: 302, headers: { 'Location' => 'https://cdn.example/1.png' })
      stub_request(:get, 'https://cdn.example/1.png').to_return(status: 302, headers: { 'Location' => 'https://cdn.example/2.png' })
      stub_request(:get, 'https://cdn.example/2.png').to_return(status: 302, headers: { 'Location' => 'https://cdn.example/3.png' })
      stub_request(:get, 'https://cdn.example/3.png').to_return(status: 302, headers: { 'Location' => 'https://cdn.example/4.png' })
      stub_icon('https://cdn.example/4.png')

      expect_fetch_error 'fetch_failed'
      expect(a_request(:get, 'https://cdn.example/4.png')).not_to have_been_made
    end

    it 'enforces a per-host request budget separate from the feed budget' do
      stub_icon(icon_url)
      ExternalBridge::RSS::Limits::ICON_HOST_BUDGET.times { fetch.call(icon_url) }
      expect_fetch_error 'rate_limited'
      expect(redis.get('external_bridge:rss:host:cdn.example')).to be_nil
    end

    context 'with a rebinding DNS answer' do
      around do |example|
        WebMock.disable!
        example.run
        WebMock.enable!
      end

      it 'refuses a host whose address is private at connect time' do
        resolver = double
        allow(resolver).to receive(:getaddresses).and_return([Resolv::IPv4.create('10.0.0.5')])
        allow(resolver).to receive(:timeouts=)
        allow(Resolv::DNS).to receive(:open).and_yield(resolver)

        expect_fetch_error 'private_address'
      end
    end

    describe 'the whole job' do
      let(:source) { icon_source(hints: [declared('atom_icon', icon_url)]) }
      let!(:subscription) { icon_subscriber(source) }

      before do
        stub_request(:get, 'https://example.com').to_return(status: 404, body: 'no')
        stub_request(:get, 'https://example.com/favicon.ico').to_return(status: 404, body: 'no')
      end

      it 'stores nothing, records the failure, and leaves the subscription alone' do
        stub_icon(icon_url, bytes: '<html>no</html>')

        expect { expect(refresh.call(source.id)).to eq 'icon_failed' }.not_to(change { subscription.reload.attributes })

        source.reload
        expect(source.icon).not_to be_present
        expect(source.icon_fingerprint).to be_nil
        expect(source.icon_failure_count).to eq 1
        expect(source.icon_next_check_at).to be > 30.minutes.from_now
        expect(subscription.reload.state).to eq 'active'
      end

      it 'records a private-address failure for a rebinding host' do
        source.update!(icon_hints: [declared('atom_icon', 'http://127.0.0.1/icon.png')])

        expect(refresh.call(source.id)).to eq 'icon_failed'
        expect(a_request(:get, /127\.0\.0\.1/)).not_to have_been_made
        expect(source.reload.icon).not_to be_present
      end
    end
  end

  describe 'sharing and re-checks' do
    let(:source) { icon_source(hints: [declared('atom_icon', icon_url)]) }

    before do
      icon_subscriber(source)
      icon_subscriber(source)
      stub_icon(icon_url, headers: { 'ETag' => '"v1"', 'Last-Modified' => 'Thu, 02 Jan 2020 03:04:05 GMT' })
    end

    it 'downloads once for any number of subscribers and polls' do
      expect(refresh.call(source.id)).to eq 'icon_stored'
      3.times { expect(refresh.call(source.id)).to eq 'skipped_not_due' }

      expect(a_request(:get, icon_url)).to have_been_made.once
      expect(source.reload.external_subscriptions.count).to eq 2
    end

    it 'sends validators and keeps the file on 304' do
      refresh.call(source.id)
      path = stored(source).icon.path(:original)
      source.update!(icon_next_check_at: 1.minute.ago)
      stub_request(:get, icon_url).with(headers: { 'If-None-Match' => '"v1"', 'If-Modified-Since' => 'Thu, 02 Jan 2020 03:04:05 GMT' }).to_return(status: 304)

      expect(refresh.call(source.id)).to eq 'icon_not_modified'

      source.reload
      expect(source.icon.path(:original)).to eq path
      expect(File.exist?(path)).to be true
      expect(source.icon_next_check_at).to be > 6.days.from_now
    end

    it 'keeps the stored file when the same bytes come back without validators' do
      refresh.call(source.id)
      path = stored(source).icon.path(:original)
      source.update!(icon_next_check_at: 1.minute.ago)

      expect(refresh.call(source.id)).to eq 'icon_unchanged'
      expect(source.reload.icon.path(:original)).to eq path
    end

    it 'follows a moved icon: same bytes at a new final address update the stored address and validators' do
      refresh.call(source.id)
      stored(source)
      source.update!(icon_next_check_at: 1.minute.ago)
      new_url = 'https://static.example/moved/icon.png'
      stub_request(:get, icon_url).to_return(status: 301, headers: { 'Location' => new_url })
      stub_icon(new_url, headers: { 'ETag' => '"v2"', 'Last-Modified' => 'Fri, 03 Jan 2020 03:04:05 GMT' })

      expect(refresh.call(source.id)).to eq 'icon_unchanged'

      source.reload
      expect(source.icon_remote_url).to eq new_url
      expect(source.icon_etag).to eq '"v2"'
      expect(source.icon_last_modified).to eq 'Fri, 03 Jan 2020 03:04:05 GMT'
      expect(source.icon_origin).to eq 'atom_icon'

      source.update!(icon_next_check_at: 1.minute.ago)
      expect(refresh.call(source.id)).to eq 'icon_unchanged'
      expect(a_request(:get, icon_url)).to have_been_made.twice
      expect(a_request(:get, new_url).with(headers: { 'If-None-Match' => '"v2"' })).to have_been_made.once
    end

    it 'follows a moved icon when the new address answers 304' do
      refresh.call(source.id)
      stored(source)
      source.update!(icon_next_check_at: 1.minute.ago)
      new_url = 'https://static.example/moved/icon.png'
      stub_request(:get, icon_url).to_return(status: 301, headers: { 'Location' => new_url })
      stub_request(:get, new_url).with(headers: { 'If-None-Match' => '"v1"' }).to_return(status: 304)

      expect(refresh.call(source.id)).to eq 'icon_not_modified'

      source.reload
      expect(source.icon_remote_url).to eq new_url
      expect(source.icon_etag).to eq '"v1"'
      expect(source.icon_last_modified).to eq 'Thu, 02 Jan 2020 03:04:05 GMT'
    end

    it 'keeps the stored address when a redirect leads somewhere that is not allowed' do
      refresh.call(source.id)
      stored(source)
      source.update!(icon_next_check_at: 1.minute.ago)
      stub_request(:get, icon_url).to_return(status: 302, headers: { 'Location' => 'http://127.0.0.1/icon.png' })
      stub_request(:get, 'https://example.com').to_return(status: 404, body: 'no')
      stub_request(:get, 'https://example.com/favicon.ico').to_return(status: 404, body: 'no')

      expect(refresh.call(source.id)).to eq 'icon_failed'

      expect(source.reload.icon_remote_url).to eq icon_url
      expect(a_request(:get, /127\.0\.0\.1/)).not_to have_been_made
    end

    it 'stores the new address when a moved icon also changed' do
      refresh.call(source.id)
      stored(source)
      source.update!(icon_next_check_at: 1.minute.ago)
      new_url = 'https://static.example/moved/icon.png'
      stub_request(:get, icon_url).to_return(status: 301, headers: { 'Location' => new_url })
      stub_icon(new_url, bytes: icon_image('png', 80, 80, [0, 0, 255]))

      expect(refresh.call(source.id)).to eq 'icon_replaced'

      source.reload
      expect(source.icon_remote_url).to eq new_url
      expect(source.icon_origin).to eq 'atom_icon'
    end

    it 'replaces a changed image and removes the old file' do
      refresh.call(source.id)
      old_path = stored(source).icon.path(:original)
      old_fingerprint = source.icon_fingerprint
      source.update!(icon_next_check_at: 1.minute.ago)
      stub_request(:get, icon_url).to_return(status: 200, body: icon_image('png', 80, 80, [0, 0, 255]), headers: { 'Content-Type' => 'image/png' })

      expect(refresh.call(source.id)).to eq 'icon_replaced'

      source.reload
      expect(source.icon_fingerprint).not_to eq old_fingerprint
      expect(File.exist?(source.icon.path(:original))).to be true
      expect(File.exist?(old_path)).to be false
    end

    it 'keeps the stored icon and backs off when a re-check hits a server error' do
      refresh.call(source.id)
      fingerprint = source.reload.icon_fingerprint
      source.update!(icon_next_check_at: 1.minute.ago)
      stub_request(:get, icon_url).to_return(status: 503, body: 'down')

      expect(refresh.call(source.id)).to eq 'icon_failed'

      source.reload
      expect(source.icon_fingerprint).to eq fingerprint
      expect(source.icon).to be_present
      expect(source.icon_failure_count).to eq 1
      expect(source.icon_next_check_at).to be > 30.minutes.from_now
    end

    it 'looks again from scratch when the stored address stops being an image' do
      refresh.call(source.id)
      source.update!(icon_next_check_at: 1.minute.ago, icon_hints: [declared('atom_icon', 'https://cdn.example/new.png')])
      stub_request(:get, icon_url).to_return(status: 404, body: 'gone')
      stub_icon('https://cdn.example/new.png', bytes: icon_image('png', 48, 48, [0, 255, 0]))

      expect(refresh.call(source.id)).to eq 'icon_replaced'
      expect(source.reload.icon_remote_url).to eq 'https://cdn.example/new.png'
    end

    it 'backs off longer after repeated failures' do
      bare = icon_source(canonical_key: 'https://other.example/feed.xml', site_url: 'https://other.example')
      icon_subscriber(bare)
      stub_request(:any, /other\.example/).to_return(status: 404, body: 'no')

      delays = 3.times.map do
        bare.update!(icon_next_check_at: 1.minute.ago)
        refresh.call(bare.id)
        bare.reload.icon_next_check_at - Time.current
      end

      expect(delays[0]).to be < 2.hours
      expect(delays[1]).to be_between(5.hours, 7.hours)
      expect(delays[2]).to be_between(23.hours, 25.hours)
    end
  end

  describe 'guards' do
    it 'does nothing for a deleted source' do
      expect(refresh.call(0)).to eq 'skipped_source_missing'
    end

    it 'does not store when the source disappears while the image is downloading' do
      source = icon_source(hints: [declared('atom_icon', icon_url)])
      icon_subscriber(source)
      stub_request(:get, icon_url).to_return do
        ExternalSubscription.where(external_source_id: source.id).delete_all
        ExternalSource.where(id: source.id).delete_all
        { status: 200, body: icon_image, headers: { 'Content-Type' => 'image/png' } }
      end

      expect(refresh.call(source.id)).to eq 'skipped_source_missing'
    end

    it 'does nothing while the feature is off or no subscription remains' do
      source = icon_source(hints: [declared('atom_icon', icon_url)])
      expect(refresh.call(source.id)).to eq 'skipped_no_subscriptions'
      icon_subscriber(source)
      Setting.external_bridge_rss = false
      expect(refresh.call(source.id)).to eq 'skipped_feature_disabled'
      expect(a_request(:get, icon_url)).not_to have_been_made
    end

    it 'skips a run while another transaction holds the source lock' do
      source = icon_source(hints: [declared('atom_icon', icon_url)])
      icon_subscriber(source)
      stub_icon(icon_url)
      other = pg_connection
      other.exec('BEGIN')
      other.exec("SELECT pg_advisory_xact_lock(#{described_class::LOCK_CLASS}, #{source.id})")

      expect(refresh.call(source.id)).to eq 'skipped_lock_busy'
      expect(a_request(:get, icon_url)).not_to have_been_made

      other.exec('COMMIT')
      expect(refresh.call(source.id)).to eq 'icon_stored'
    ensure
      other&.close
    end

    it 'holds the lock while the image downloads' do
      source = icon_source(hints: [declared('atom_icon', icon_url)])
      icon_subscriber(source)
      held = nil
      stub_request(:get, icon_url).to_return do
        held = ApplicationRecord.connection.select_value(<<~SQL.squish)
          SELECT count(*) FROM pg_locks
          WHERE locktype = 'advisory' AND classid = #{described_class::LOCK_CLASS} AND objid = #{source.id} AND granted AND pid = pg_backend_pid()
        SQL
        { status: 200, body: icon_image, headers: { 'Content-Type' => 'image/png' } }
      end

      expect(refresh.call(source.id)).to eq 'icon_stored'
      expect(held.to_i).to eq 1
    end

    def pg_connection
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      PG.connect(dbname: config[:database], user: config[:username], password: config[:password], host: config[:host], port: config[:port])
    end
  end

  # Real commits are needed to see the lock leave the database: inside the
  # rolled-back spec transaction a transaction-scoped lock would live until
  # the example ends.
  describe 'advisory lock lifetime across real transactions' do
    self.use_transactional_tests = false

    let(:feed_site) { 'https://lock-test.example' }
    let(:image_url) { 'https://cdn.example/lock-test.png' }

    before do
      Setting.external_bridge_rss = true
      @source = ExternalSource.create!(
        protocol: 'rss', canonical_key: "#{feed_site}/feed.xml", title: 'Lock test', site_url: feed_site,
        fetched_at: Time.current, checked_at: Time.current, icon_hints: [declared('atom_icon', image_url)]
      )
      @user = Fabricate(:user)
      enable_external_bridge_rss!(@user)
      ExternalSubscription.create!(user: @user, external_source: @source, state: 'active')
    end

    after do
      ExternalSubscription.where(external_source_id: @source.id).delete_all
      @source.icon.destroy
      ExternalSource.where(id: @source.id).delete_all
      @user.account.destroy
      @user.destroy
      Setting.external_bridge_rss = false
    end

    def lock_free?(source_id)
      other = pg_connection
      other.exec('BEGIN')
      free = other.exec("SELECT pg_try_advisory_xact_lock(#{described_class::LOCK_CLASS}, #{source_id})").getvalue(0, 0) == 't'
      other.exec('ROLLBACK')
      free
    ensure
      other&.close
    end

    def pg_connection
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      PG.connect(dbname: config[:database], user: config[:username], password: config[:password], host: config[:host], port: config[:port])
    end

    it 'releases the lock after a successful run commits' do
      stub_icon(image_url)

      expect(refresh.call(@source.id)).to eq 'icon_stored'

      expect(lock_free?(@source.id)).to be true
      expect(ApplicationRecord.connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid = #{described_class::LOCK_CLASS}").to_i).to eq 0
    end

    it 'never issues a session unlock: the transaction end releases the lock' do
      stub_icon(image_url)
      statements = []
      allow(ApplicationRecord.connection).to receive(:execute).and_wrap_original do |original, sql, *args|
        statements << sql.to_s
        original.call(sql, *args)
      end
      allow(ApplicationRecord.connection).to receive(:select_value).and_wrap_original do |original, sql, *args|
        statements << sql.to_s
        original.call(sql, *args)
      end

      expect(refresh.call(@source.id)).to eq 'icon_stored'

      expect(statements.grep(/pg_advisory_unlock|pg_try_advisory_lock\b|pg_advisory_lock\b/)).to be_empty
      expect(statements.grep(/pg_try_advisory_xact_lock/).size).to eq 1
      expect(lock_free?(@source.id)).to be true
    end

    it 'releases the lock after a skipped run and after a failed run' do
      stub_icon(image_url, status: 404, type: 'text/plain')
      stub_request(:get, feed_site).to_return(status: 404, body: 'no')
      stub_request(:get, "#{feed_site}/favicon.ico").to_return(status: 404, body: 'no')

      expect(refresh.call(@source.id)).to eq 'icon_failed'
      expect(lock_free?(@source.id)).to be true
      expect(refresh.call(@source.id)).to eq 'skipped_not_due'
      expect(lock_free?(@source.id)).to be true
    end

    it 'releases the lock and rolls back when the run raises' do
      allow_any_instance_of(ExternalBridge::RSS::Icon::ImageFetch).to receive(:call).and_raise(RuntimeError, 'boom')

      expect { refresh.call(@source.id) }.to raise_error(RuntimeError, 'boom')

      expect(lock_free?(@source.id)).to be true
      expect(@source.reload.icon_failure_count).to eq 0
    end

    it 'still reports a busy lock to a second run and succeeds once the holder commits' do
      stub_icon(image_url)
      holder = pg_connection
      holder.exec('BEGIN')
      holder.exec("SELECT pg_advisory_xact_lock(#{described_class::LOCK_CLASS}, #{@source.id})")

      expect(refresh.call(@source.id)).to eq 'skipped_lock_busy'
      holder.exec('COMMIT')
      expect(refresh.call(@source.id)).to eq 'icon_stored'
    ensure
      holder&.close
    end

    it 'lets only one of two concurrent runs download' do
      entered = Queue.new
      release = Queue.new
      # The per-host budget uses a Redis connection that a second thread must not share.
      allow_any_instance_of(ExternalBridge::RSS::HttpClient).to receive(:consume_budget!)
      stub_request(:get, image_url).to_return do
        entered << true
        Timeout.timeout(15) { release.pop }
        { status: 200, body: icon_image, headers: { 'Content-Type' => 'image/png' } }
      end
      source_id = @source.id

      first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { described_class.new.call(source_id) } }
      Timeout.timeout(15) { entered.pop }
      second = ActiveRecord::Base.connection_pool.with_connection { described_class.new.call(source_id) }
      release << true

      expect(second).to eq 'skipped_lock_busy'
      expect(first.value).to eq 'icon_stored'
      expect(a_request(:get, image_url)).to have_been_made.once
      expect(lock_free?(source_id)).to be true
    ensure
      release << true
      first&.join(15)
    end
  end
end
# rubocop:enable Metrics/BlockLength
