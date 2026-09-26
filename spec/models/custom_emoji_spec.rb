require 'rails_helper'

RSpec.describe CustomEmoji, type: :model do
  describe '#search' do
    let(:custom_emoji) { Fabricate(:custom_emoji, shortcode: shortcode) }

    subject { described_class.search(search_term) }

    context 'shortcode is exact' do
      let(:shortcode) { 'blobpats' }
      let(:search_term) { 'blobpats' }

      it 'finds emoji' do
        is_expected.to include(custom_emoji)
      end
    end

    context 'shortcode is partial' do
      let(:shortcode) { 'blobpats' }
      let(:search_term) { 'blob' }

      it 'finds emoji' do
        is_expected.to include(custom_emoji)
      end
    end
  end

  describe '#local?' do
    let(:custom_emoji) { Fabricate(:custom_emoji, domain: domain) }

    subject { custom_emoji.local? }

    context 'domain is nil' do
      let(:domain) { nil }

      it 'returns true' do
        is_expected.to be true
      end
    end

    context 'domain is present' do
      let(:domain) { 'example.com' }

      it 'returns false' do
        is_expected.to be false
      end
    end
  end

  describe '#object_type' do
    it 'returns :emoji' do
      custom_emoji = Fabricate(:custom_emoji)
      expect(custom_emoji.object_type).to be :emoji
    end
  end

  describe '.from_text' do
    let!(:emojo) { Fabricate(:custom_emoji) }

    subject { described_class.from_text(text, nil) }

    context 'with plain text' do
      let(:text) { 'Hello :coolcat:' }

      it 'returns records used via shortcodes in text' do
        is_expected.to include(emojo)
      end
    end

    context 'with html' do
      let(:text) { '<p>Hello :coolcat:</p>' }

      it 'returns records used via shortcodes in text' do
        is_expected.to include(emojo)
      end
    end

    context 'with adjacent shortcodes' do
      let!(:foo) { Fabricate(:custom_emoji, shortcode: 'foo') }
      let!(:bar) { Fabricate(:custom_emoji, shortcode: 'bar') }
      let(:text) { ':foo::bar:' }

      it 'recognizes each shortcode' do
        expect(described_class.from_text(text, nil).map(&:shortcode)).to contain_exactly('foo', 'bar')
      end
    end
  end

  describe '.with_compatible_boundaries' do
    let(:foo) { Fabricate(:custom_emoji, shortcode: 'foo') }
    let(:bar) { Fabricate(:custom_emoji, shortcode: 'bar') }
    let(:baz) { Fabricate(:custom_emoji, shortcode: 'baz') }

    # Colon is intentionally accepted as an emoji boundary. Do not assert that
    # an IPv6 segment which is itself a colon-delimited custom emoji shortcode
    # stays literal; that misreading is an accepted Fedibird tradeoff.

    it 'separates two adjacent recognized shortcodes with one zero-width space' do
      converted = described_class.with_compatible_boundaries(':foo::bar:', [foo, bar])

      expect(converted).to eq(":foo:\u200B:bar:")
      expect(described_class.with_compatible_boundaries(converted, [foo, bar])).to eq(converted)
    end

    it 'separates three adjacent recognized shortcodes' do
      expect(described_class.with_compatible_boundaries(':foo::bar::baz:', [foo, bar, baz])).to eq(":foo:\u200B:bar:\u200B:baz:")
    end

    it 'fills only the boundary that is not already separated' do
      expect(described_class.with_compatible_boundaries(":foo:\u200B:bar::baz:", [foo, bar, baz])).to eq(":foo:\u200B:bar:\u200B:baz:")
    end

    it 'keeps multibyte text around the inserted boundary' do
      expect(described_class.with_compatible_boundaries('。:foo::bar:', [foo, bar])).to eq("。:foo:\u200B:bar:")
    end

    it 'does not rewrite colon sequences that are not a pair of recognized shortcodes' do
      expect(described_class.with_compatible_boundaries('2001:db8::1234', [foo, bar])).to eq('2001:db8::1234')
      expect(described_class.with_compatible_boundaries('foo::bar', [foo, bar])).to eq('foo::bar')
      expect(described_class.with_compatible_boundaries(':foo::nope:', [foo, bar])).to eq(':foo::nope:')
    end
  end

  describe 'pre_validation' do
    let(:custom_emoji) { Fabricate(:custom_emoji, domain: 'wWw.MaStOdOn.CoM') }

    it 'should downcase' do
      custom_emoji.valid?
      expect(custom_emoji.domain).to eq('www.mastodon.com')
    end
  end
end
