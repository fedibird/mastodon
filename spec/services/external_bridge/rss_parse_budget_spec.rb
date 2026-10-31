# frozen_string_literal: true

require 'rails_helper'
require 'fiddle'
require 'tmpdir'

# Records libxml external-entity loads. The loader is process-global, so it
# is restored before the example returns. A null result means "no bytes".
module RssEntityLoaderProbe
  module_function

  def capturing
    library = Fiddle.dlopen(nokogiri_so)
    setter = Fiddle::Function.new(library['xmlSetExternalEntityLoader'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
    getter = Fiddle::Function.new(library['xmlGetExternalEntityLoader'], [], Fiddle::TYPE_VOIDP)
    calls = []
    callback = Fiddle::Closure::BlockCaller.new(
      Fiddle::TYPE_VOIDP,
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
    ) do |url, identifier, _context|
      calls << [pointer_string(url), pointer_string(identifier)]
      Fiddle::NULL
    end
    previous = getter.call
    setter.call(callback)
    begin
      yield calls
    ensure
      setter.call(previous)
    end
  end

  def nokogiri_so
    version = RUBY_VERSION.split('.').take(2).join('.')
    File.join(Gem.loaded_specs.fetch('nokogiri').full_gem_path, 'lib/nokogiri', version, 'nokogiri.so')
  end

  def pointer_string(value)
    return nil if value.nil? || (value.respond_to?(:null?) && value.null?)

    value.to_s
  end
end

RSpec.describe ExternalBridge::RSS::DocumentBudget do
  def budget(**overrides)
    described_class::Budget.default.tap do |item|
      overrides.each { |key, value| item[key] = value }
    end
  end

  def expect_oversized(body, **overrides)
    expect { described_class.check!(body, budget: budget(**overrides)) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end

  it 'accepts a document at the byte cap and rejects one extra byte' do
    xml = '<r/>'
    expect(described_class.check!(xml, budget: budget(max_bytes: xml.bytesize))).to eq xml
    expect_oversized(xml, max_bytes: xml.bytesize - 1)

    cap = 32
    expect { ExternalBridge::RSS::Parser.parse!('a' * cap, budget: budget(max_bytes: cap)) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }
    expect { ExternalBridge::RSS::Parser.parse!(('a' * (cap + 1)), budget: budget(max_bytes: cap)) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end

  it 'counts UTF-8 text, CDATA, and comments in bytes' do
    text = ExternalBridge::RSS::SyntheticFeed.text_node(4, char: 'あ')
    expect(text).to include('あ')
    expect(described_class.check!(text, budget: budget(max_text_bytes: 12))).to eq text
    expect_oversized(text, max_text_bytes: 11)

    cdata = '<r><![CDATA[abcdef]]></r>'
    expect(described_class.check!(cdata, budget: budget(max_text_bytes: 6))).to eq cdata
    expect_oversized(cdata, max_text_bytes: 5)

    comment = '<r><!--abcdef--></r>'
    expect(described_class.check!(comment, budget: budget(max_text_bytes: 6))).to eq comment
    expect_oversized(comment, max_text_bytes: 5)
  end

  it 'rejects one element, one level, or one attribute past the budget' do
    elements = ExternalBridge::RSS::SyntheticFeed.repeated_elements(2)
    expect(described_class.check!(elements, budget: budget(max_elements: 3))).to eq elements
    expect_oversized(elements, max_elements: 2)

    nested = ExternalBridge::RSS::SyntheticFeed.deep(3)
    expect(described_class.check!(nested, budget: budget(max_depth: 3))).to eq nested
    expect_oversized(nested, max_depth: 2)

    attrs = ExternalBridge::RSS::SyntheticFeed.repeated_attributes(2, value: 'あ')
    expect(described_class.check!(attrs, budget: budget(max_attributes: 2, max_attribute_bytes: 3))).to eq attrs
    expect_oversized(attrs, max_attributes: 1)
    expect_oversized(attrs, max_attribute_bytes: 2)

    one = '<r a="v"/>'
    expect(described_class.check!(one, budget: budget(max_attribute_total: 1))).to eq one
    expect_oversized('<r a="v" b="v"/>', max_attribute_total: 1)
  end

  it 'uses the product ceilings for depth, elements, and attributes' do
    limits = ExternalBridge::RSS::Limits
    expect(described_class.check!(ExternalBridge::RSS::SyntheticFeed.deep(limits::MAX_XML_DEPTH))).to include('<e0>')
    expect_oversized(ExternalBridge::RSS::SyntheticFeed.deep(limits::MAX_XML_DEPTH + 1))

    expect(described_class.check!(ExternalBridge::RSS::SyntheticFeed.repeated_attributes(limits::MAX_XML_ATTRIBUTES))).to include('a0=')
    expect_oversized(ExternalBridge::RSS::SyntheticFeed.repeated_attributes(limits::MAX_XML_ATTRIBUTES + 1))

    under = ExternalBridge::RSS::SyntheticFeed.repeated_elements(limits::MAX_XML_ELEMENTS - 1)
    over = ExternalBridge::RSS::SyntheticFeed.repeated_elements(limits::MAX_XML_ELEMENTS)
    expect(described_class.check!(under)).to include('<e/>')
    expect_oversized(over)
  end

  it 'parses a feed at the element and attribute-node caps' do
    limits = ExternalBridge::RSS::Limits
    elements = ExternalBridge::RSS::SyntheticFeed.element_cap_feed(elements: limits::MAX_XML_ELEMENTS)
    feed = ExternalBridge::RSS::Parser.parse!(elements)
    expect(feed.items.size).to eq limits::MAX_ITEMS
    expect(feed.items.first.key).to eq 'synthetic-0001'
    expect(feed.items.last.key).to eq 'synthetic-0040'
    expect { ExternalBridge::RSS::Parser.parse!(elements.sub('</channel>', '<e/></channel>')) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }

    at_attributes = ExternalBridge::RSS::SyntheticFeed.attribute_total_feed(attributes: limits::MAX_XML_ATTRIBUTES_TOTAL)
    expect(ExternalBridge::RSS::Parser.parse!(at_attributes).items.size).to eq limits::MAX_ITEMS
    over_attributes = ExternalBridge::RSS::SyntheticFeed.attribute_total_feed(attributes: limits::MAX_XML_ATTRIBUTES_TOTAL + 1)
    expect { ExternalBridge::RSS::Parser.parse!(over_attributes) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end

  it 'stops on the budget and does not report the later syntax error' do
    xml = +'<r>'
    20.times { xml << '<e/>' }
    xml << '<broken'
    expect_oversized(xml, max_elements: 3)
  end

  it 'rejects an internal entity bomb before a DOM is built and does not load it' do
    payload = +%(<?xml version="1.0"?>\n<!DOCTYPE r [\n<!ENTITY a "aaaaaaaaaa">\n)
    previous = 'a'
    'b'.upto('f') do |name|
      payload << %(<!ENTITY #{name} "#{Array.new(10) { "&#{previous};" }.join}">\n)
      previous = name
    end
    payload << "]>\n<r>&#{previous};</r>\n"

    RssEntityLoaderProbe.capturing do |calls|
      expect(Nokogiri::XML::Document).not_to receive(:parse)
      expect { ExternalBridge::RSS::Parser.parse!(payload) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
      expect(calls).to eq []
    end
  end

  it 'rejects a custom internal entity instead of substituting it' do
    xml = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE rss [<!ENTITY nick "SECRET-NICK">]>
      <rss version="2.0"><channel><title>&nick;</title><link>https://feeds.example/a</link>
        <item><guid>g</guid><title>t</title><link>https://articles.example/n</link></item>
      </channel></rss>
    XML

    RssEntityLoaderProbe.capturing do |calls|
      expect(Nokogiri::XML::Document).not_to receive(:parse)
      expect { ExternalBridge::RSS::Parser.parse!(xml) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }
      expect(calls).to eq []
    end
  end

  it 'does not load an external general entity from file or http' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'hostname')
      File.write(path, 'SENTINEL-NOT-A-HOSTNAME')
      file_xml = %(<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x SYSTEM "file://#{path}">]><rss version="2.0"><channel><title>&x;</title></channel></rss>)
      http_xml = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE rss [<!ENTITY xxe SYSTEM "http://127.0.0.1/xxe-secret">]>
        <rss version="2.0"><channel><title>&xxe;</title></channel></rss>
      XML
      https_xml = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE rss [<!ENTITY xxe SYSTEM "https://feeds.example/secret.ent">]>
        <rss version="2.0"><channel><title>&xxe;</title></channel></rss>
      XML
      stub_request(:get, 'http://127.0.0.1/xxe-secret').to_return(status: 200, body: 'SECRET')
      stub_request(:get, 'https://feeds.example/secret.ent').to_return(status: 200, body: 'SECRET')

      [file_xml, http_xml, https_xml].each do |xml|
        RssEntityLoaderProbe.capturing do |calls|
          expect { ExternalBridge::RSS::Parser.parse!(xml) }
            .to raise_error(ExternalBridge::Error) { |error| expect(error.message).to eq 'invalid_xml' }
          expect(calls).to eq []
        end
      end
      expect(a_request(:get, 'http://127.0.0.1/xxe-secret')).not_to have_been_made
      expect(a_request(:get, 'https://feeds.example/secret.ent')).not_to have_been_made
    end
  end

  it 'does not load a parameter entity or an external DTD' do
    parameter = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE rss [<!ENTITY % remote SYSTEM "http://127.0.0.1/remote.dtd"> %remote;]>
      <rss version="2.0"><channel><title>Kept</title><link>https://feeds.example/a</link>
        <item><guid>g</guid><title>t</title><link>https://articles.example/n</link></item>
      </channel></rss>
    XML
    external = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE rss SYSTEM "http://127.0.0.1/rss.dtd">
      <rss version="2.0"><channel><title>Kept</title><link>https://feeds.example/a</link>
        <item><guid>g</guid><title>t</title><link>https://articles.example/n</link></item>
      </channel></rss>
    XML
    stub_request(:get, 'http://127.0.0.1/remote.dtd').to_return(status: 200, body: '<!ENTITY stolen "SECRET">')
    stub_request(:get, 'http://127.0.0.1/rss.dtd').to_return(status: 200, body: '<!ELEMENT rss ANY>')

    RssEntityLoaderProbe.capturing do |calls|
      feed = ExternalBridge::RSS::Parser.parse!(parameter)
      expect(feed.title).to eq 'Kept'
      external_feed = ExternalBridge::RSS::Parser.parse!(external)
      expect(external_feed.title).to eq 'Kept'
      expect(calls).to eq []
    end
    expect(a_request(:get, 'http://127.0.0.1/remote.dtd')).not_to have_been_made
    expect(a_request(:get, 'http://127.0.0.1/rss.dtd')).not_to have_been_made
  end

  it 'still reads predefined entities and a doctype that declares none' do
    xml = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE rss>
      <rss version="2.0"><channel><title>A &amp; B &#38; C</title><link>https://feeds.example/a</link>
        <item><guid>g</guid><title>t</title><link>https://articles.example/n</link></item>
      </channel></rss>
    XML

    expect(ExternalBridge::RSS::Parser.parse!(xml).title).to eq 'A & B & C'
  end

  it 'does not build a DOM when the structure budget fails' do
    xml = ExternalBridge::RSS::SyntheticFeed.repeated_elements(8)
    expect(Nokogiri::XML::Document).not_to receive(:parse)
    expect { ExternalBridge::RSS::Parser.parse!(xml, budget: budget(max_elements: 2)) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end
end

RSpec.describe ExternalBridge::RSS::Parser do
  it 'drops an illegal XML control and still rejects a truncated document' do
    xml = %(<rss version="2.0"><channel><title>Ada\u0007</title><link>https://feeds.example/a</link>) +
          '<item><guid>g</guid><title>t</title><link>https://articles.example/n</link></item></channel></rss>'
    feed = described_class.parse!(xml)

    expect(feed.title).to eq 'Ada'
    expect(feed.items.size).to eq 1
    expect { described_class.parse!(xml.delete_suffix('</rss>')) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }

    padded = ("\u0007" * 8) + '<r/>'
    expect { ExternalBridge::RSS::DocumentBudget.check!(padded, budget: ExternalBridge::RSS::DocumentBudget::Budget.default.tap { |item| item.max_bytes = padded.bytesize - 1 }) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'oversized_feed' }
  end

  it 'rejects a truncated tail, an open CDATA section, and a missing root close' do
    feed = ExternalBridge::RSS::SyntheticFeed
    [feed.broken_after, feed.unclosed_cdata, feed.missing_close].each do |xml|
      expect { described_class.parse!(xml) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }
    end
  end

  it 'returns only the first 40 items of a longer well-formed feed' do
    feed = described_class.parse!(ExternalBridge::RSS::SyntheticFeed.compact(items: 45))

    expect(feed.items.size).to eq ExternalBridge::RSS::Limits::MAX_ITEMS
    expect(feed.items.first.key).to eq 'synthetic-0001'
    expect(feed.items.last.key).to eq 'synthetic-0040'
  end

  it 'keeps the feed byte cap and the other fetch profiles unchanged' do
    limits = ExternalBridge::RSS::Limits
    client = ExternalBridge::RSS::HttpClient
    expect(limits::MAX_PARSE_BYTES).to eq 4.megabytes
    expect(limits::MAX_RESPONSE_BYTES).to eq 4.megabytes
    expect(limits::MAX_RECEIVED_BYTES).to eq 4.megabytes
    expect(limits::MAX_ITEMS).to eq 40
    expect(client::FEED_PROFILE.max_received_bytes).to eq limits::MAX_RECEIVED_BYTES
    expect(client::FEED_PROFILE.max_inflated_bytes).to eq limits::MAX_RESPONSE_BYTES
    expect(client::NODEINFO_PROFILE.max_bytes).to eq 64.kilobytes
    expect(client::ACTIVITYPUB_PROFILE.max_bytes).to eq 256.kilobytes
    expect(client::ICON_IMAGE_PROFILE.max_bytes).to eq limits::ICON_MAX_BYTES
    expect(client::MEDIA_IMAGE_PROFILE.max_bytes).to eq limits::MEDIA_IMAGE_MAX_BYTES
    expect(client::ICON_PAGE_PROFILE.max_bytes).to eq limits::ICON_MAX_PAGE_BYTES
    expect(client::ICON_PAGE_PROFILE.truncate).to be true
  end
end

RSpec.describe 'parser budget failures and stored feed rows' do
  let(:user) { Fabricate(:user) }
  let(:feed_url) { 'https://feeds.example/budget.xml' }

  before do
    enable_external_bridge_rss!(user)
    redis.keys('external_bridge:rss:host:*').each { |key| redis.del(key) }
  end

  it 'does not create a source, resource, subscription, or projection on the first failure' do
    stub_request(:get, feed_url).to_return(status: 200, body: ExternalBridge::RSS::SyntheticFeed.broken_after)

    expect { ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url) }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'invalid_xml' }

    expect(ExternalSource.where(canonical_key: feed_url)).to be_empty
    expect(ExternalResource.where('canonical_key LIKE ?', '%budget.xml%')).to be_empty
    expect(ExternalSubscription.where(user_id: user.id)).to be_empty
    expect(ExternalStatusProjection.where(user_id: user.id)).to be_empty
  end

  it 'keeps the cached article and schedules a retry when a later fetch is truncated' do
    stub_request(:get, feed_url).to_return(
      status: 200,
      body: rss_document(rss_item(guid: 'kept', body: 'Visible article')),
      headers: { 'ETag' => 'W/"kept"', 'Last-Modified' => 'Thu, 02 Jan 2020 03:04:05 GMT' }
    )
    subscription = ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
    source = subscription.external_source
    resource = source.external_resources.first
    projection = ExternalStatusProjection.find_by!(user: user, external_resource: resource)
    source.update!(fetched_at: 1.hour.ago, checked_at: 1.hour.ago)
    subscription.update!(checked_at: 2.hours.ago)
    kept = source.reload.attributes.slice('etag', 'last_modified', 'fetched_at')

    stub_request(:get, feed_url).to_return(status: 200, body: ExternalBridge::RSS::SyntheticFeed.broken_after)
    ExternalBridge::RSS::RefreshSource.new.call(source.id)

    expect(source.reload.attributes.slice('etag', 'last_modified', 'fetched_at')).to eq kept
    expect(resource.reload.body).to eq 'Visible article'
    expect(ExternalStatusProjection.find(projection.id).status_id).to eq projection.status_id
    expect(subscription.reload.last_error_code).to eq 'invalid_xml'
    expect(subscription.retry_count).to eq 1
    expect(subscription.next_retry_at).to be > Time.current
  end
end
