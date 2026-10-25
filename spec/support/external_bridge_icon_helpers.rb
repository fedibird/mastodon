# frozen_string_literal: true

require 'open3'

module ExternalBridgeIconHelpers
  # Solid-colour raster bytes built in Ruby. ImageMagick's policy on CI
  # images often forbids the `xc:` coder, and the fetch path only needs a valid
  # file.
  def icon_image(format = 'png', width = 64, height = width, color = nil)
    color ||= [255, 0, 0]
    ICON_IMAGE_CACHE[[format, width, height, color]] ||= begin
      png = solid_png(width, height, color)
      format == 'ico' ? ico_wrapping(png, width, height) : png
    end
  end

  def solid_png(width, height, color)
    chunk = lambda do |type, data|
      [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
    end
    row = "\x00".b + color.pack('C3') * width
    raw = Zlib::Deflate.deflate(row * height)
    "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', [width, height, 8, 2, 0, 0, 0].pack('NNCCCCC')) + chunk.call('IDAT', raw) + chunk.call('IEND', '')
  end

  def ico_wrapping(png, width, height)
    header = [0, 1, 1].pack('vvv')
    entry = [width % 256, height % 256, 0, 0, 1, 32, png.bytesize, 22].pack('CCCCvvVV')
    header + entry + png
  end

  def stub_icon(url, bytes: nil, type: 'image/png', status: 200, headers: {})
    stub_request(:get, url).to_return(
      status: status,
      body: bytes || icon_image,
      headers: { 'Content-Type' => type }.merge(headers)
    )
  end

  def icon_source(site_url: 'https://example.com', canonical_key: 'https://example.com/feed.xml', hints: [], **extra)
    ExternalSource.create!(
      {
        protocol: 'rss',
        canonical_key: canonical_key,
        title: 'Example feed',
        site_url: site_url,
        fetched_at: Time.current,
        checked_at: Time.current,
        icon_hints: hints,
      }.merge(extra)
    )
  end

  def icon_subscriber(source, user = Fabricate(:user))
    enable_external_bridge_rss!(user)
    ExternalSubscription.create!(user: user, external_source: source, state: 'active')
  end

  # Stores a real icon through the production job, so a spec that only needs
  # "a source with an icon" exercises the same path.
  def store_icon!(source, url: 'https://cdn.example/stored.png', bytes: nil)
    icon_subscriber(source) unless source.external_subscriptions.exists?
    source.update!(icon_hints: [declared('atom_icon', url)], icon_next_check_at: nil)
    stub_icon(url, bytes: bytes)
    ExternalBridge::RSS::Icon::RefreshSource.new.call(source.id)
    source.reload
  end

  def declared(kind, url)
    { 'kind' => kind, 'url' => url }
  end

  ICON_IMAGE_CACHE = {}
end

RSpec.configure do |config|
  config.include ExternalBridgeIconHelpers
end
