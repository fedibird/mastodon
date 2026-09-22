# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::Parser::CustomEmojiParser do
  subject do
    described_class.new(
      'id' => 'https://example.com/emoji/blob',
      'name' => ':blob:',
      'icon' => { 'url' => 'https://example.com/emoji/blob.png' },
      'updated' => '2022-03-04T05:06:07Z'
    )
  end

  it 'reads the URI, shortcode, icon URL, and updated timestamp' do
    expect(subject.uri).to eq 'https://example.com/emoji/blob'
    expect(subject.shortcode).to eq 'blob'
    expect(subject.image_remote_url).to eq 'https://example.com/emoji/blob.png'
    expect(subject.updated_at).to eq '2022-03-04T05:06:07Z'.to_datetime
  end

  it 'returns nil for a missing shortcode or an unparseable timestamp' do
    parser = described_class.new('updated' => 'not-a-date')

    expect(parser.shortcode).to be_nil
    expect(parser.updated_at).to be_nil
    expect(parser.image_remote_url).to be_nil
  end
end
