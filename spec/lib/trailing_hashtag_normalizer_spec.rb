# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TrailingHashtagNormalizer do
  describe '.call' do
    {
      'Hello #one #two' => "Hello\n#one #two",
      "Hello\n#one #two" => "Hello\n#one #two",
      "Hello\n\n#one #two" => "Hello\n\n#one #two",
      '#one #two' => '#one #two',
      'Hello #inline text #end' => "Hello #inline text\n#end",
      'Hello #one,' => 'Hello #one,',
      'Hello #one @alice' => 'Hello #one @alice',
      'Hello #one https://example.com/' => 'Hello #one https://example.com/',
      'Hello ＃タグ' => "Hello\n＃タグ",
      'Hello #日本語' => "Hello\n#日本語",
      'Hello   #one' => "Hello\n#one",
      "Hello\t#one" => "Hello\n#one",
      'Hello #one   ' => "Hello\n#one   ",
      "Hello \n #one" => "Hello \n #one",
      "Hello\r\n#one" => "Hello\r\n#one",
      '   #one' => '   #one',
    }.each do |input, expected|
      it "normalizes #{input.inspect}" do
        expect(described_class.call(input)).to eq expected
      end
    end

    it 'returns an empty string for nil' do
      expect(described_class.call(nil)).to eq ''
    end
  end
end
