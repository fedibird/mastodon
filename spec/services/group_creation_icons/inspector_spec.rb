# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupCreationIcons::Inspector do
  include ExternalBridgeIconHelpers

  def inspect_bytes(bytes, filename: 'icon.bin', type: 'application/octet-stream')
    file = Tempfile.new(['icon', File.extname(filename)])
    file.binmode
    file.write(bytes)
    file.flush
    upload = Rack::Test::UploadedFile.new(file.path, type, original_filename: filename)
    described_class.call(upload)
  ensure
    file.close!
  end

  it 'accepts avatar image types from the bytes and ignores the client type' do
    jpeg = File.binread(Rails.root.join('spec/fixtures/files/attachment.jpg'))
    result = inspect_bytes(jpeg, filename: 'photo.svg', type: 'image/svg+xml')

    expect(result).to be_ok
    expect(result.mime).to eq 'image/jpeg'
    expect(result.byte_size).to eq jpeg.bytesize
  end

  it 'accepts png, gif, webp, bmp, and ico' do
    samples = {
      'image/png' => icon_image('png'),
      'image/gif' => File.binread(Rails.root.join('spec/fixtures/files/mini-static.gif')),
      'image/webp' => File.binread(Rails.root.join('spec/fixtures/files/attachment.webp')),
      'image/bmp' => bmp_1x1,
      'image/vnd.microsoft.icon' => icon_image('ico'),
    }

    samples.each do |mime, bytes|
      result = inspect_bytes(bytes, filename: 'x.bin', type: 'text/plain')
      expect(result).to be_ok, mime
      expect(result.mime).to eq mime
    end
  end

  it 'rejects svg, a claimed heic file, corrupt bytes, an empty file, and an oversized file' do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>)
    heic = "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00".b

    expect(inspect_bytes(svg, filename: 'a.jpg', type: 'image/jpeg')).not_to be_ok
    expect(inspect_bytes(heic, filename: 'a.jpg', type: 'image/jpeg').error).to eq(:type_not_allowed).or eq(:corrupt).or eq(:spoofed)
    expect(inspect_bytes('not an image', type: 'image/png').error).to eq(:type_not_allowed).or eq(:corrupt).or eq(:spoofed)
    expect(inspect_bytes('', type: 'image/png').error).to eq :empty
    expect(described_class.call(StringIO.new('a' * AccountAvatar::LIMIT)).error).to eq :too_large
    expect(described_class.call('spec/fixtures/files/attachment.jpg').error).to eq :unreadable
  end

  it 'rejects an ICO whose DIB is only a BITMAPINFOHEADER' do
    result = inspect_bytes(header_only_dib_ico, filename: 'header.ico', type: 'image/vnd.microsoft.icon')

    expect(result).not_to be_ok
  end

  it 'accepts an ICO whose DIB contains the XOR bitmap and the AND mask' do
    result = inspect_bytes(solid_dib_ico, filename: 'solid.ico', type: 'image/vnd.microsoft.icon')

    expect(result).to be_ok
    expect(result.mime).to eq 'image/vnd.microsoft.icon'
  end

  it 'rejects an ICO whose embedded PNG has valid chunks but does not decode' do
    result = inspect_bytes(undecodable_png_ico, filename: 'broken.ico', type: 'image/vnd.microsoft.icon')

    expect(result).not_to be_ok
  end

  it 'rejects an ICO whose directory points at missing image bytes' do
    result = inspect_bytes(directory_only_ico, filename: 'broken.ico', type: 'image/vnd.microsoft.icon')

    expect(result).not_to be_ok
  end

  it 'rejects a PNG that has a valid signature and IHDR but no image data' do
    result = inspect_bytes(header_only_png, filename: 'broken.png', type: 'image/png')

    expect(result.error).to eq :corrupt
  end

  it 'rejects an image with too many pixels' do
    result = described_class.call(Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/4096x4097.png'), 'image/png'))

    expect(result.error).to eq :too_many_pixels
  end

  it 'keeps the avatar allowlist and does not add heic, avif, or svg' do
    migration = File.read(Rails.root.join('db/migrate/20261111120000_add_group_creation_request_icons.rb'))

    expect(AccountAvatar::LIMIT).to eq 4_194_304
    AccountAvatar::IMAGE_MIME_TYPES.each do |mime|
      expect(migration).to include(mime)
    end
    expect(migration).not_to match(/heic|heif|avif|svg/i)
    expect(GroupCreationIcons::FAST_IMAGE_TYPES.values).to match_array(AccountAvatar::IMAGE_MIME_TYPES)
  end

  def header_only_dib_ico
    dib = [40, 16, 32, 1, 32, 0, 0, 0, 0, 0, 0].pack('VVVvvVVVVVV')
    [0, 1, 1].pack('vvv') + [16, 16, 0, 0, 1, 32, dib.bytesize, 22].pack('CCCCvvVV') + dib
  end

  def solid_dib_ico
    xor_row = ((1 * 32) + 31) / 32 * 4
    mask_row = (1 + 31) / 32 * 4
    dib = [40, 1, 2, 1, 32, 0, 0, 0, 0, 0, 0].pack('VVVvvVVVVVV')
    dib += "\x00".b * (xor_row + mask_row)
    [0, 1, 1].pack('vvv') + [1, 1, 0, 0, 1, 32, dib.bytesize, 22].pack('CCCCvvVV') + dib
  end

  def undecodable_png_ico
    ihdr = [8, 8, 8, 2, 0, 0, 0].pack('NNCCCCC')
    png = png_chunk('IHDR', ihdr) + png_chunk('IDAT', 'not zlib'.b) + png_chunk('IEND', ''.b)
    ico_wrapping("\x89PNG\r\n\x1a\n".b + png, 8, 8)
  end

  def png_chunk(type, data)
    [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
  end

  def directory_only_ico
    [0, 1, 1].pack('vvv') + [16, 16, 0, 0, 1, 32, 100, 22].pack('CCCCvvVV')
  end

  def header_only_png
    signature = "\x89PNG\r\n\x1a\n".b
    data = [8, 8, 8, 2, 0, 0, 0].pack('NNCCCCC')
    chunk = [data.bytesize].pack('N') + 'IHDR' + data + [Zlib.crc32('IHDR' + data)].pack('N')
    signature + chunk
  end

  def bmp_1x1
    row = "\xff\x00\x00\x00".b
    file_header = 'BM'.b + [54 + row.bytesize, 0, 0, 54].pack('VvvV')
    info = [40, 1, 1, 1, 24, 0, 4, 2835, 2835, 0, 0].pack('VllvvVVllVV')
    file_header + info + row
  end
end
