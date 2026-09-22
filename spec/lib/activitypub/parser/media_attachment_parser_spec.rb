# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::Parser::MediaAttachmentParser do
  let(:json) do
    {
      'url' => 'https://cdn.example.com/files/cat.jpg',
      'icon' => { 'url' => 'https://cdn.example.com/files/cat-thumb.jpg' },
      'summary' => '  a cat  ',
      'name' => 'unused name',
      'focalPoint' => [0.1, -0.2],
      'blurhash' => 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
      'mediaType' => 'image/jpeg',
    }
  end

  subject { described_class.new(json) }

  it 'reads the remote URL, thumbnail, description, focus, blurhash, and media type' do
    expect(subject.remote_url).to eq 'https://cdn.example.com/files/cat.jpg'
    expect(subject.thumbnail_remote_url).to eq 'https://cdn.example.com/files/cat-thumb.jpg'
    expect(subject.description).to eq 'a cat'
    expect(subject.focus).to eq [0.1, -0.2]
    expect(subject.blurhash).to eq 'LEHV6nWB2yk8pyo0adR*.7kCMdnj'
    expect(subject.file_content_type).to eq 'image/jpeg'
  end

  it 'accepts a thumbnail URL stored as a string and falls back to name' do
    parser = described_class.new('url' => 'https://cdn.example.com/a.png', 'icon' => 'https://cdn.example.com/a-thumb.png', 'name' => ' alt ')

    expect(parser.thumbnail_remote_url).to eq 'https://cdn.example.com/a-thumb.png'
    expect(parser.description).to eq 'alt'
  end

  it 'returns nil for an invalid remote or thumbnail URL' do
    parser = described_class.new('url' => 'http://foo\bar', 'icon' => { 'url' => 'ht!tp://thumb' })

    expect(parser.remote_url).to be_nil
    expect(parser.thumbnail_remote_url).to be_nil
  end

  it 'drops a blurhash whose components exceed the supported size' do
    parser = described_class.new(json.merge('blurhash' => '5~TI:j|cfQ|cfQ|c'))

    expect(parser.blurhash).to be_nil
  end

  it 'drops a blurhash with unsupported characters' do
    parser = described_class.new(json.merge('blurhash' => 'not valid'))

    expect(parser.blurhash).to be_nil
  end

  it 'truncates the description to the media attachment limit' do
    parser = described_class.new('summary' => 'x' * (MediaAttachment::MAX_DESCRIPTION_LENGTH + 20))

    expect(parser.description.length).to eq MediaAttachment::MAX_DESCRIPTION_LENGTH
  end

  describe '#significantly_changes?' do
    let(:previous) do
      Struct.new(:remote_url, :thumbnail_remote_url, :description).new(
        'https://cdn.example.com/files/cat.jpg',
        'https://cdn.example.com/files/cat-thumb.jpg',
        'a cat'
      )
    end

    it 'is false when the remote URL, thumbnail, and description match' do
      expect(subject.significantly_changes?(previous)).to be false
    end

    it 'is true when the remote URL, thumbnail, or description changes' do
      expect(described_class.new(json.merge('url' => 'https://cdn.example.com/files/other.jpg')).significantly_changes?(previous)).to be true
      expect(described_class.new(json.merge('icon' => { 'url' => 'https://cdn.example.com/files/other-thumb.jpg' })).significantly_changes?(previous)).to be true
      expect(described_class.new(json.merge('summary' => 'a dog')).significantly_changes?(previous)).to be true
    end
  end
end
