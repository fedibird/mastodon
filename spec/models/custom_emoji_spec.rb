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

    context 'with a shortcode beside other characters' do
      let!(:foo) { Fabricate(:custom_emoji, shortcode: 'foo') }
      let!(:bar) { Fabricate(:custom_emoji, shortcode: 'bar') }

      [
        ':foo:',
        'abc:foo:',
        ':foo:def',
        'abc:foo:def',
        '日本語:foo:です',
        '(:foo:)',
      ].each do |sample|
        it "recognizes foo in #{sample}" do
          expect(described_class.from_text(sample, nil).map(&:shortcode)).to include('foo')
        end
      end

      it 'recognizes each adjacent shortcode' do
        expect(described_class.from_text(':foo::bar:', nil).map(&:shortcode)).to contain_exactly('foo', 'bar')
      end
    end
  end

  describe '.with_compatible_boundaries' do
    let(:foo) { Fabricate(:custom_emoji, shortcode: 'foo') }
    let(:bar) { Fabricate(:custom_emoji, shortcode: 'bar') }
    let(:baz) { Fabricate(:custom_emoji, shortcode: 'baz') }
    let(:emojis) { [foo, bar, baz] }

    # Fedibird recognizes a known :shortcode: regardless of surrounding
    # characters, including rare IPv6-like text. Do not assert that an IPv6
    # segment which is itself a colon-delimited custom emoji shortcode stays
    # literal; that misreading is an accepted tradeoff. Sequences that are not
    # a recognized shortcode stay unchanged.

    it 'isolates a recognized shortcode from non-whitespace text and is idempotent' do
      {
        ':foo:' => ':foo:',
        ' :foo:' => ' :foo:',
        ':foo: ' => ':foo: ',
        'abc:foo:' => "abc\u200B:foo:",
        ':foo:def' => ":foo:\u200Bdef",
        'abc:foo:def' => "abc\u200B:foo:\u200Bdef",
        '日本語:foo:' => "日本語\u200B:foo:",
        ':foo:です' => ":foo:\u200Bです",
        '今日は:foo:です' => "今日は\u200B:foo:\u200Bです",
        '(:foo:)' => "(\u200B:foo:\u200B)",
        '「:foo:」' => "「\u200B:foo:\u200B」",
        ':foo::bar:' => ":foo:\u200B:bar:",
        ':foo::bar::baz:' => ":foo:\u200B:bar:\u200B:baz:",
        'abc:foo::bar:def' => "abc\u200B:foo:\u200B:bar:\u200Bdef",
        '。:foo::bar:' => "。\u200B:foo:\u200B:bar:",
      }.each do |input, expected|
        converted = described_class.with_compatible_boundaries(input, emojis)

        expect(converted).to eq(expected)
        expect(described_class.with_compatible_boundaries(converted, emojis)).to eq(converted)
      end
    end

    it 'does not add a boundary beside whitespace, including tab, newline, and nbsp' do
      expect(described_class.with_compatible_boundaries("\t:foo:\n", emojis)).to eq("\t:foo:\n")
      expect(described_class.with_compatible_boundaries(":foo:\r", emojis)).to eq(":foo:\r")
      expect(described_class.with_compatible_boundaries('  :foo:  ', emojis)).to eq('  :foo:  ')
      expect(described_class.with_compatible_boundaries("\u00A0:foo:\u00A0", emojis)).to eq("\u00A0:foo:\u00A0")
    end

    it 'does not double an existing zero-width space and fills only the open side' do
      already = "abc\u200B:foo:\u200Bdef"

      expect(described_class.with_compatible_boundaries(already, emojis)).to eq(already)
      expect(described_class.with_compatible_boundaries("abc\u200B:foo:def", emojis)).to eq("abc\u200B:foo:\u200Bdef")
      expect(described_class.with_compatible_boundaries(":foo:\u200Bdef", emojis)).to eq(":foo:\u200Bdef")
      expect(described_class.with_compatible_boundaries(":foo:\u200B:bar::baz:", emojis)).to eq(":foo:\u200B:bar:\u200B:baz:")
    end

    it 'does not rewrite text that is not a recognized shortcode' do
      expect(described_class.with_compatible_boundaries('abc:not_an_emoji:def', emojis)).to eq('abc:not_an_emoji:def')
      expect(described_class.with_compatible_boundaries('2001:db8::1234', emojis)).to eq('2001:db8::1234')
      expect(described_class.with_compatible_boundaries('foo::bar', emojis)).to eq('foo::bar')
      expect(described_class.with_compatible_boundaries(':foo::nope:', emojis)).to eq(":foo:\u200B:nope:")
    end
  end

  describe 'pre_validation' do
    let(:custom_emoji) { Fabricate(:custom_emoji, domain: 'wWw.MaStOdOn.CoM') }

    it 'should downcase' do
      custom_emoji.valid?
      expect(custom_emoji.domain).to eq('www.mastodon.com')
    end
  end

  describe 'emoji reaction cache invalidation' do
    let(:custom_emoji) { Fabricate(:custom_emoji, shortcode: 'cachemoji') }
    let(:status) { Fabricate(:status) }
    let(:account) { Fabricate(:account) }

    before do
      allow(RefreshDirtyEmojiReactionCachesWorker).to receive(:perform_async)
      allow(PostProcessEmojiReactionCacheWorker).to receive(:perform_async)
      EmojiReaction.create!(account: account, status: status, name: custom_emoji.shortcode, custom_emoji: custom_emoji)
      status.status_stat.update!(emoji_reactions_cache_dirty: false)
    end

    def expect_dirty
      expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be true
      expect(RefreshDirtyEmojiReactionCachesWorker).to have_received(:perform_async)
      expect(PostProcessEmojiReactionCacheWorker).not_to have_received(:perform_async)
    end

    it 'dirties related statuses when the emoji is disabled' do
      custom_emoji.update!(disabled: true)

      expect_dirty
    end

    it 'dirties related statuses when a disabled emoji is enabled' do
      custom_emoji.update!(disabled: true)
      status.status_stat.update!(emoji_reactions_cache_dirty: false)

      custom_emoji.update!(disabled: false)

      expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be true
      expect(RefreshDirtyEmojiReactionCachesWorker).to have_received(:perform_async).twice
    end

    it 'dirties related statuses when the image timestamp changes' do
      custom_emoji.update!(image_updated_at: 1.hour.from_now)

      expect_dirty
    end

    it 'dirties related statuses when dimensions change' do
      custom_emoji.update!(width: 12, height: 13)

      expect_dirty
    end

    it 'dirties related statuses when alternate_name changes' do
      custom_emoji.update!(alternate_name: '別')

      expect_dirty
    end

    it 'dirties related statuses when ruby changes' do
      custom_emoji.update!(ruby: 'るび')

      expect_dirty
    end

    it 'dirties related statuses when the shortcode changes' do
      custom_emoji.update!(shortcode: 'cachemoji2')

      expect_dirty
    end

    it 'dirties related statuses when the domain changes' do
      custom_emoji.update!(domain: 'emoji.example')

      expect_dirty
    end

    it 'does not dirty statuses for metadata that is absent from the reaction cache' do
      custom_emoji.update!(description: 'not cached', license: 'CC0', visible_in_picker: false, creator: 'artist')

      expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be false
      expect(RefreshDirtyEmojiReactionCachesWorker).not_to have_received(:perform_async)
    end

    it 'leaves the status dirty after destroy cascades the reaction rows away' do
      custom_emoji.destroy!

      expect(EmojiReaction.where(custom_emoji_id: custom_emoji.id)).to be_empty
      expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be true
      expect(RefreshDirtyEmojiReactionCachesWorker).to have_received(:perform_async)
    end

    it 'does not keep a dirty mark when destroy rolls back' do
      CustomEmoji.transaction do
        custom_emoji.destroy!
        raise ActiveRecord::Rollback
      end

      expect(custom_emoji.reload).to be_persisted
      expect(EmojiReaction.where(custom_emoji: custom_emoji)).to exist
      expect(status.status_stat.reload.emoji_reactions_cache_dirty).to be false
      expect(RefreshDirtyEmojiReactionCachesWorker).not_to have_received(:perform_async)
    end
  end
end
