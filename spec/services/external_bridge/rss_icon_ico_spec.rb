# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe ExternalBridge::RSS::Icon::IcoValidator do
  def png(size, color = [10, 20, 30])
    solid_png(size, size, color)
  end

  def png_entry(size)
    { width: size, height: size, payload: png(size) }
  end

  def dib_entry(size, **options)
    { width: size, height: size, payload: dib_payload(size, size, **options), bit_count: options.fetch(:bit_count, 32) }
  end

  def validate(bytes)
    described_class.validate!(bytes)
  end

  def reject(bytes)
    expect { validate(bytes) }.to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'icon_invalid_ico' }
  end

  describe 'accepted files' do
    it 'accepts a single PNG image' do
      expect(validate(ico_from([png_entry(32)]))).to eq [32, 32]
    end

    it 'accepts a single 32 bpp bitmap with its mask' do
      expect(validate(ico_from([dib_entry(16)]))).to eq [16, 16]
    end

    it 'accepts bitmaps without a mask and with a palette' do
      expect(validate(ico_from([{ width: 16, height: 16, payload: dib_payload(16, 16, with_mask: false) }]))).to eq [16, 16]
      expect(validate(ico_from([dib_entry(32, bit_count: 8)]))).to eq [32, 32]
    end

    it 'accepts several entries and reports the largest' do
      expect(validate(ico_from([dib_entry(16), dib_entry(32), png_entry(48)]))).to eq [48, 48]
    end

    it 'reads a directory size of zero as 256' do
      expect(validate(ico_from([{ width: 256, height: 256, payload: png(256) }]))).to eq [256, 256]
    end
  end

  describe 'rejected files' do
    it 'rejects a truncated or empty file' do
      reject('')
      reject("\x00\x00\x01\x00".b)
      reject(ico_from([png_entry(32)]).byteslice(0, 10))
    end

    it 'rejects a wrong type, a reserved value, and a bad count' do
      valid = ico_from([png_entry(32)])
      reject([0, 2, 1].pack('vvv') + valid.byteslice(6, valid.bytesize))
      reject([1, 1, 1].pack('vvv') + valid.byteslice(6, valid.bytesize))
      reject([0, 1, 0].pack('vvv') + valid.byteslice(6, valid.bytesize))
      reject(ico_from([png_entry(32)], header_count: 2))
    end

    it 'rejects more entries than the limit' do
      reject(ico_from(Array.new(described_class::MAX_ENTRIES + 1) { dib_entry(16) }))
    end

    it 'rejects a valid header over a payload that is not an image' do
      reject(ico_from([{ width: 32, height: 32, payload: 'A' * 400 }]))
      reject(ico_from([{ width: 32, height: 32, payload: "<html>#{'x' * 300}</html>" }]))
    end

    it 'rejects a PNG payload whose chunks are cut off' do
      bytes = png(32)
      reject(ico_from([{ width: 32, height: 32, payload: bytes.byteslice(0, bytes.bytesize - 20) }]))
      reject(ico_from([{ width: 32, height: 32, payload: bytes.byteslice(0, 40) }]))
    end

    it 'rejects a PNG payload with a corrupted chunk' do
      bytes = png(32).b
      bytes.setbyte(bytes.bytesize - 20, bytes.getbyte(bytes.bytesize - 20) ^ 0xff)
      reject(ico_from([{ width: 32, height: 32, payload: bytes }]))
    end

    it 'rejects a PNG whose header disagrees with the directory entry' do
      reject(ico_from([{ width: 16, height: 16, payload: png(32) }]))
    end

    it 'rejects a PNG with data after IEND or with no IEND' do
      reject(ico_from([{ width: 32, height: 32, payload: [png(32), 'trailing'].join }]))
      iend = png(32).byteslice(-12, 12)
      reject(ico_from([{ width: 32, height: 32, payload: png(32).delete_suffix(iend) }]))
    end

    it 'rejects a bitmap whose pixel data is missing' do
      payload = dib_payload(32, 32)
      reject(ico_from([{ width: 32, height: 32, payload: payload.byteslice(0, 200) }]))
    end

    it 'rejects a bitmap whose header disagrees with the entry' do
      reject(ico_from([{ width: 32, height: 32, payload: dib_payload(16, 16) }]))
      payload = dib_payload(16, 16).b
      payload[14, 2] = [7].pack('v')
      reject(ico_from([{ width: 16, height: 16, payload: payload }]))
    end

    it 'rejects a bitmap with a compression method that is not allowed' do
      payload = dib_payload(16, 16).b
      payload[16, 4] = [1].pack('V')
      reject(ico_from([{ width: 16, height: 16, payload: payload }]))
    end

    it 'rejects an entry that points outside the file or into the directory' do
      valid = ico_from([png_entry(32)]).b
      out_of_bounds = valid.dup
      out_of_bounds[18, 4] = [valid.bytesize].pack('V')
      reject(out_of_bounds)
      into_directory = valid.dup
      into_directory[18, 4] = [2].pack('V')
      reject(into_directory)
    end

    it 'rejects overlapping entries' do
      valid = ico_from([png_entry(32), png_entry(32)]).b
      overlapping = valid.dup
      overlapping[6 + 16 + 12, 4] = overlapping[6 + 12, 4]
      reject(overlapping)
    end

    it 'rejects bytes that no entry describes' do
      reject([ico_from([png_entry(32)]), 'hidden payload'].join)
    end
  end

  describe 'as an icon candidate' do
    let(:fetch) { ExternalBridge::RSS::Icon::ImageFetch.new }

    def respond_with(bytes)
      stub_icon('https://example.com/favicon.ico', bytes: bytes, type: 'image/x-icon')
      fetch.call('https://example.com/favicon.ico')
    end

    it 'returns the largest image size for a valid ICO' do
      result = respond_with(ico_from([dib_entry(16), dib_entry(32)]))
      expect([result.type, result.width, result.height]).to eq [:ico, 32, 32]
    end

    it 'fails closed on an ICO that only has a valid header' do
      expect { respond_with(ico_from([{ width: 32, height: 32, payload: 'A' * 400 }])) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'icon_invalid_ico' }
    end

    it 'applies the size limits to the largest entry' do
      expect { respond_with(ico_from([dib_entry(8)])) }
        .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq 'icon_too_small' }
    end
  end

  describe 'through the whole job' do
    before { Setting.external_bridge_rss = true }

    it 'stores nothing and tries the next candidate when the ICO is broken' do
      source = icon_source(hints: [declared('atom_icon', 'https://cdn.example/broken.ico'), declared('rss_image', 'https://cdn.example/good.png')])
      icon_subscriber(source)
      stub_icon('https://cdn.example/broken.ico', bytes: ico_from([{ width: 32, height: 32, payload: 'A' * 400 }]), type: 'image/x-icon')
      stub_icon('https://cdn.example/good.png')

      expect(ExternalBridge::RSS::Icon::RefreshSource.new.call(source.id)).to eq 'icon_stored'
      expect(source.reload.icon_remote_url).to eq 'https://cdn.example/good.png'
    end

    it 'records a failure when only a broken ICO exists' do
      source = icon_source(hints: [declared('atom_icon', 'https://cdn.example/broken.ico')])
      icon_subscriber(source)
      stub_icon('https://cdn.example/broken.ico', bytes: ico_from([{ width: 32, height: 32, payload: 'A' * 400 }]), type: 'image/x-icon')
      stub_request(:get, 'https://example.com').to_return(status: 404, body: 'no')
      stub_request(:get, 'https://example.com/favicon.ico').to_return(status: 404, body: 'no')

      expect(ExternalBridge::RSS::Icon::RefreshSource.new.call(source.id)).to eq 'icon_failed'
      expect(source.reload.icon).not_to be_present
    end

    it 'stores a valid multi-entry ICO byte for byte' do
      bytes = ico_from([dib_entry(16), dib_entry(32), png_entry(48)])
      source = icon_source(hints: [declared('atom_icon', 'https://cdn.example/favicon.ico')])
      icon_subscriber(source)
      stub_icon('https://cdn.example/favicon.ico', bytes: bytes, type: 'image/vnd.microsoft.icon')

      expect(ExternalBridge::RSS::Icon::RefreshSource.new.call(source.id)).to eq 'icon_stored'
      expect(File.binread(source.reload.icon.path(:original))).to eq bytes
    end
  end
end
# rubocop:enable Metrics/BlockLength
