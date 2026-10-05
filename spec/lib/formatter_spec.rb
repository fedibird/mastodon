require 'rails_helper'

RSpec.describe Formatter do
  let(:local_account)  { Fabricate(:account, domain: nil, username: 'alice') }
  let(:remote_account) { Fabricate(:account, domain: 'remote.test', username: 'bob', url: 'https://remote.test/') }

  shared_examples 'encode and link URLs' do
    context 'given a stand-alone medium URL' do
      let(:text) { 'https://hackernoon.com/the-power-to-build-communities-a-response-to-mark-zuckerberg-3f2cac9148a4' }

      it 'matches the full URL' do
        is_expected.to include 'href="https://hackernoon.com/the-power-to-build-communities-a-response-to-mark-zuckerberg-3f2cac9148a4"'
      end
    end

    context 'given a stand-alone google URL' do
      let(:text) { 'http://google.com' }

      it 'matches the full URL' do
        is_expected.to include 'href="http://google.com"'
      end
    end

    context 'given a stand-alone URL with a newer TLD' do
      let(:text) { 'http://example.gay' }

      it 'matches the full URL' do
        is_expected.to include 'href="http://example.gay"'
      end
    end

    context 'given a stand-alone IDN URL' do
      let(:text) { 'https://nic.みんな/' }

      it 'matches the full URL' do
        is_expected.to include 'href="https://nic.みんな/"'
      end

      it 'has display URL' do
        is_expected.to include '<span class="">nic.みんな/</span>'
      end
    end

    context 'given a URL with a trailing period' do
      let(:text) { 'http://www.mcmansionhell.com/post/156408871451/50-states-of-mcmansion-hell-scottsdale-arizona. ' }

      it 'matches the full URL but not the period' do
        is_expected.to include 'href="http://www.mcmansionhell.com/post/156408871451/50-states-of-mcmansion-hell-scottsdale-arizona"'
      end
    end

    context 'given a URL enclosed with parentheses' do
      let(:text) { '(http://google.com/)' }

      it 'matches the full URL but not the parentheses' do
        is_expected.to include 'href="http://google.com/"'
      end
    end

    context 'given a URL with a trailing exclamation point' do
      let(:text) { 'http://www.google.com!' }

      it 'matches the full URL but not the exclamation point' do
        is_expected.to include 'href="http://www.google.com"'
      end
    end

    context 'given a URL with a trailing single quote' do
      let(:text) { "http://www.google.com'" }

      it 'matches the full URL but not the single quote' do
        is_expected.to include 'href="http://www.google.com"'
      end
    end

    context 'given a URL with a trailing angle bracket' do
      let(:text) { 'http://www.google.com>' }

      it 'matches the full URL but not the angle bracket' do
        is_expected.to include 'href="http://www.google.com"'
      end
    end

    context 'given a URL with a query string' do
      context 'with escaped unicode character' do
        let(:text) { 'https://www.ruby-toolbox.com/search?utf8=%E2%9C%93&q=autolink' }

        it 'matches the full URL' do
          is_expected.to include 'href="https://www.ruby-toolbox.com/search?utf8=%E2%9C%93&amp;q=autolink"'
        end
      end

      context 'with unicode character' do
        let(:text) { 'https://www.ruby-toolbox.com/search?utf8=✓&q=autolink' }

        it 'matches the full URL' do
          is_expected.to include 'href="https://www.ruby-toolbox.com/search?utf8=✓&amp;q=autolink"'
        end
      end

      context 'with unicode character at the end' do
        let(:text) { 'https://www.ruby-toolbox.com/search?utf8=✓' }

        it 'matches the full URL' do
          is_expected.to include 'href="https://www.ruby-toolbox.com/search?utf8=✓"'
        end
      end

      context 'with escaped and not escaped unicode characters' do
        let(:text) { 'https://www.ruby-toolbox.com/search?utf8=%E2%9C%93&utf81=✓&q=autolink' }

        it 'preserves escaped unicode characters' do
          is_expected.to include 'href="https://www.ruby-toolbox.com/search?utf8=%E2%9C%93&amp;utf81=✓&amp;q=autolink"'
        end
      end
    end

    context 'given a URL with parentheses in it' do
      let(:text) { 'https://en.wikipedia.org/wiki/Diaspora_(software)' }

      it 'matches the full URL' do
        is_expected.to include 'href="https://en.wikipedia.org/wiki/Diaspora_(software)"'
      end
    end

    context 'given a URL in quotation marks' do
      let(:text) { '"https://example.com/"' }

      it 'does not match the quotation marks' do
        is_expected.to include 'href="https://example.com/"'
      end
    end

    context 'given a URL in angle brackets' do
      let(:text) { '<https://example.com/>' }

      it 'does not match the angle brackets' do
        is_expected.to include 'href="https://example.com/"'
      end
    end

    context 'given a URL with Japanese path string' do
      let(:text) { 'https://ja.wikipedia.org/wiki/日本' }

      it 'matches the full URL' do
        is_expected.to include 'href="https://ja.wikipedia.org/wiki/日本"'
      end
    end

    context 'given a URL with Korean path string' do
      let(:text) { 'https://ko.wikipedia.org/wiki/대한민국' }

      it 'matches the full URL' do
        is_expected.to include 'href="https://ko.wikipedia.org/wiki/대한민국"'
      end
    end

    context 'given a URL with a full-width space' do
      let(:text) { 'https://example.com/　abc123' }

      it 'does not match the full-width space' do
        is_expected.to include 'href="https://example.com/"'
      end
    end

    context 'given a URL in Japanese quotation marks' do
      let(:text) { '「[https://example.org/」' }

      it 'does not match the quotation marks' do
        is_expected.to include 'href="https://example.org/"'
      end
    end

    context 'given a URL with Simplified Chinese path string' do
      let(:text) { 'https://baike.baidu.com/item/中华人民共和国' }

      it 'matches the full URL' do
        is_expected.to include 'href="https://baike.baidu.com/item/中华人民共和国"'
      end
    end

    context 'given a URL with Traditional Chinese path string' do
      let(:text) { 'https://zh.wikipedia.org/wiki/臺灣' }

      it 'matches the full URL' do
        is_expected.to include 'href="https://zh.wikipedia.org/wiki/臺灣"'
      end
    end

    context 'given a URL containing unsafe code (XSS attack, visible part)' do
      let(:text) { %q{http://example.com/b<del>b</del>} }

      it 'does not include the HTML in the URL' do
        is_expected.to include '"http://example.com/b"'
      end

      it 'escapes the HTML' do
        is_expected.to include '&lt;del&gt;b&lt;/del&gt;'
      end
    end

    context 'given a URL containing unsafe code (XSS attack, invisible part)' do
      let(:text) { %q{http://example.com/blahblahblahblah/a<script>alert("Hello")</script>} }

      it 'does not include the HTML in the URL' do
        is_expected.to include '"http://example.com/blahblahblahblah/a"'
      end

      it 'escapes the HTML' do
        is_expected.to include '&lt;script&gt;alert(&quot;Hello&quot;)&lt;/script&gt;'
      end
    end

    context 'given text containing HTML code (script tag)' do
      let(:text) { '<script>alert("Hello")</script>' }

      it 'escapes the HTML' do
        is_expected.to include '<p>&lt;script&gt;alert(&quot;Hello&quot;)&lt;/script&gt;</p>'
      end
    end

    context 'given text containing HTML (XSS attack)' do
      let(:text) { %q{<img src="javascript:alert('XSS');">} }

      it 'escapes the HTML' do
        is_expected.to include '<p>&lt;img src=&quot;javascript:alert(&apos;XSS&apos;);&quot;&gt;</p>'
      end
    end

    context 'given an invalid URL' do
      let(:text) { 'http://www\.google\.com' }

      it 'outputs the raw URL' do
        is_expected.to eq '<p>http://www\.google\.com</p>'
      end
    end

    context 'given text containing a hashtag' do
      let(:text)  { '#hashtag' }

      it 'creates a hashtag link' do
        is_expected.to include '/tags/hashtag" class="mention hashtag" rel="tag">#<span>hashtag</span></a>'
      end
    end

    context 'given text containing a hashtag with Unicode chars' do
      let(:text)  { '#hashtagタグ' }

      it 'creates a hashtag link' do
        is_expected.to include '/tags/hashtag%E3%82%BF%E3%82%B0" class="mention hashtag" rel="tag">#<span>hashtagタグ</span></a>'
      end
    end

    context 'given a stand-alone xmpp: URI' do
      let(:text) { 'xmpp:user@instance.com' }

      it 'matches the full URI' do
        is_expected.to include 'href="xmpp:user@instance.com"'
      end
    end

    context 'given a an xmpp: URI with a query-string' do
      let(:text) { 'please join xmpp:muc@instance.com?join right now' }

      it 'matches the full URI' do
        is_expected.to include 'href="xmpp:muc@instance.com?join"'
      end
    end

    context 'given text containing a magnet: URI' do
      let(:text) { 'wikipedia gives this example of a magnet uri: magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a' }

      it 'matches the full URI' do
        is_expected.to include 'href="magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a"'
      end
    end
  end

  describe '#format_spoiler' do
    subject { Formatter.instance.format_spoiler(status) }

    context 'given a post containing plain text' do
      let(:status) { Fabricate(:status, text: 'text', spoiler_text: 'Secret!', uri: nil) }

      it 'Returns the spoiler text' do
        is_expected.to eq 'Secret!'
      end
    end

    context 'given a post with an emoji shortcode at the start' do
      let!(:emoji) { Fabricate(:custom_emoji) }
      let(:status) { Fabricate(:status, text: 'text', spoiler_text: ':coolcat: Secret!', uri: nil) }
      let(:text) { ':coolcat: Beep boop' }

      it 'converts the shortcode to an image tag' do
        is_expected.to match(/<img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
      end
    end
  end

  describe '#format' do
    subject { Formatter.instance.format(status) }

    context 'given a post with local status' do
      context 'given a reblogged post' do
        let(:reblog) { Fabricate(:status, account: local_account, text: 'Hello world', uri: nil) }
        let(:status) { Fabricate(:status, reblog: reblog) }

        it 'returns original status with credit to its author' do
          is_expected.to include 'RT <span class="h-card"><a href="https://cb6e6126.ngrok.io/@alice" class="u-url mention">@<span>alice</span></a></span> Hello world'
        end
      end

      context 'given a post containing plain text' do
        let(:status) { Fabricate(:status, text: 'text', uri: nil) }

        it 'paragraphizes the text' do
          is_expected.to eq '<p>text</p>'
        end
      end

      context 'given a post containing line feeds' do
        let(:status) { Fabricate(:status, text: "line\nfeed", uri: nil) }

        it 'removes line feeds' do
          is_expected.not_to include "\n"
        end
      end

      context 'given a post containing linkable mentions' do
        let(:status) { Fabricate(:status, mentions: [ Fabricate(:mention, account: local_account) ], text: '@alice') }

        it 'creates a mention link' do
          is_expected.to include '<a href="https://cb6e6126.ngrok.io/@alice" class="u-url mention">@<span>alice</span></a></span>'
        end
      end

      context 'given a post containing unlinkable mentions' do
        let(:status) { Fabricate(:status, text: '@alice', uri: nil) }

        it 'does not create a mention link' do
          is_expected.to include '@alice'
        end
      end

      context do
        subject do
          status = Fabricate(:status, text: text, uri: nil)
          Formatter.instance.format(status)
        end

        include_examples 'encode and link URLs'
      end

      context 'given a post with custom_emojify option' do
        let!(:emoji) { Fabricate(:custom_emoji) }
        let(:status) { Fabricate(:status, account: local_account, text: text) }

        subject { Formatter.instance.format(status, custom_emojify: true) }

        context 'given a post with an emoji shortcode at the start' do
          let(:text) { ':coolcat: Beep boop' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/<p><img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with an emoji shortcode in the middle' do
          let(:text) { 'Beep :coolcat: boop' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/Beep <img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with concatenated emoji shortcodes' do
          let(:text) { ':coolcat::coolcat:' }

          it 'converts each adjacent shortcode to an image' do
            expect(subject.scan('alt=":coolcat:"').size).to eq(2)
            expect(subject).not_to include(':coolcat::coolcat:')
          end
        end

        context 'given a shortcode touching non-whitespace text' do
          let(:text) { 'abc:coolcat:def' }

          it 'converts the shortcode to an image without a zero-width space' do
            fragment = Nokogiri::HTML.fragment(subject)

            expect(fragment.css('img.custom-emoji').size).to eq(1)
            expect(fragment.text).to eq('abcdef')
            expect(subject).not_to include("\u200B")
          end
        end

        context 'given a post with an emoji shortcode at the end' do
          let(:text) { 'Beep boop :coolcat:' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/boop <img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end
      end
    end

    context 'given a post with remote status' do
      let(:status) { Fabricate(:status, account: remote_account, text: 'Beep boop') }

      it 'reformats the post' do
        is_expected.to eq 'Beep boop'
      end

      context 'given a post with custom_emojify option' do
        let!(:emoji) { Fabricate(:custom_emoji, domain: remote_account.domain) }
        let(:status) { Fabricate(:status, account: remote_account, text: text) }

        subject { Formatter.instance.format(status, custom_emojify: true) }

        context 'given a post with an emoji shortcode at the start' do
          let(:text) { '<p>:coolcat: Beep boop<br />' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/<p><img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with an emoji shortcode in the middle' do
          let(:text) { '<p>Beep :coolcat: boop</p>' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/Beep <img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with concatenated emoji' do
          let(:text) { '<p>:coolcat::coolcat:</p>' }

          it 'converts each adjacent shortcode to an image' do
            expect(subject.scan('alt=":coolcat:"').size).to eq(2)
            expect(subject).not_to include(':coolcat::coolcat:')
          end
        end

        context 'given a shortcode touching non-whitespace text' do
          let(:text) { '<p>今日は:coolcat:です</p>' }

          it 'converts the shortcode to an image without a zero-width space' do
            fragment = Nokogiri::HTML.fragment(subject)

            expect(fragment.css('img.custom-emoji').size).to eq(1)
            expect(fragment.text).to eq('今日はです')
            expect(subject).not_to include("\u200B")
          end
        end

        context 'given a post with an emoji shortcode at the end' do
          let(:text) { '<p>Beep boop<br />:coolcat:</p>' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/<br><img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end
      end
    end
  end

  describe '#reformat' do
    subject { Formatter.instance.reformat(text) }

    context 'given a post containing plain text' do
      let(:text) { 'Beep boop' }

      it 'keeps the plain text' do
        is_expected.to include 'Beep boop'
      end
    end

    context 'given a post containing script tags' do
      let(:text) { '<script>alert("Hello")</script>' }

      it 'strips the scripts' do
        is_expected.to_not include '<script>alert("Hello")</script>'
      end
    end

    context 'given a post containing malicious classes' do
      let(:text) { '<span class="mention	status__content__spoiler-link">Show more</span>' }

      it 'strips the malicious classes' do
        is_expected.to_not include 'status__content__spoiler-link'
      end
    end
  end

  describe '#plaintext' do
    subject { Formatter.instance.plaintext(status) }

    context 'given a post with local status' do
      let(:status) { Fabricate(:status, text: '<p>a text by a nerd who uses an HTML tag in text</p>', uri: nil) }

      it 'returns the raw text' do
        is_expected.to eq '<p>a text by a nerd who uses an HTML tag in text</p>'
      end
    end

    context 'given a post with remote status' do
      let(:status) { Fabricate(:status, account: remote_account, text: '<script>alert("Hello")</script>') }

      it 'returns tag-stripped text' do
        is_expected.to eq ''
      end
    end
  end

  describe '#simplified_format' do
    subject { Formatter.instance.simplified_format(account) }

    context 'given a post with local status' do
      let(:account) { Fabricate(:account, domain: nil, note: text) }

      context 'given a post containing linkable mentions for local accounts' do
        let(:text) { '@alice' }

        before { local_account }

        it 'creates a mention link' do
          is_expected.to eq '<p><span class="h-card"><a href="https://cb6e6126.ngrok.io/@alice" class="u-url mention">@<span>alice</span></a></span></p>'
        end
      end

      context 'given a post containing linkable mentions for remote accounts' do
        let(:text) { '@bob@remote.test' }

        before { remote_account }

        it 'creates a mention link' do
          is_expected.to eq '<p><span class="h-card"><a href="https://remote.test/" class="u-url mention">@<span>bob</span></a></span></p>'
        end
      end

      context 'given a post containing unlinkable mentions' do
        let(:text) { '@alice' }

        it 'does not create a mention link' do
          is_expected.to eq '<p>@alice</p>'
        end
      end

      context 'given a post with custom_emojify option' do
        let!(:emoji) { Fabricate(:custom_emoji) }

        before { account.note = text }
        subject { Formatter.instance.simplified_format(account, custom_emojify: true) }

        context 'given a post with an emoji shortcode at the start' do
          let(:text) { ':coolcat: Beep boop' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/<p><img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with an emoji shortcode in the middle' do
          let(:text) { 'Beep :coolcat: boop' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/Beep <img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with concatenated emoji shortcodes' do
          let(:text) { ':coolcat::coolcat:' }

          it 'converts each adjacent shortcode to an image' do
            expect(subject.scan('alt=":coolcat:"').size).to eq(2)
            expect(subject).not_to include(':coolcat::coolcat:')
          end
        end

        context 'given a post with an emoji shortcode at the end' do
          let(:text) { 'Beep boop :coolcat:' }

          it 'converts the shortcode to an image tag' do
            is_expected.to match(/boop <img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end
      end

      include_examples 'encode and link URLs'
    end

    context 'given a post with remote status' do
      let(:text) { '<script>alert("Hello")</script>' }
      let(:account) { Fabricate(:account, domain: 'remote', note: text) }

      it 'reformats' do
        is_expected.to_not include '<script>alert("Hello")</script>'
      end

      context 'with custom_emojify option' do
        let!(:emoji) { Fabricate(:custom_emoji, domain: remote_account.domain) }

        before { remote_account.note = text }

        subject { Formatter.instance.simplified_format(remote_account, custom_emojify: true) }

        context 'given a post with an emoji shortcode at the start' do
          let(:text) { '<p>:coolcat: Beep boop<br />' }

          it 'converts shortcode to image tag' do
            is_expected.to match(/<p><img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with an emoji shortcode in the middle' do
          let(:text) { '<p>Beep :coolcat: boop</p>' }

          it 'converts shortcode to image tag' do
            is_expected.to match(/Beep <img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end

        context 'given a post with concatenated emoji shortcodes' do
          let(:text) { '<p>:coolcat::coolcat:</p>' }

          it 'converts each adjacent shortcode to an image' do
            expect(subject.scan('alt=":coolcat:"').size).to eq(2)
            expect(subject).not_to include(':coolcat::coolcat:')
          end
        end

        context 'given a post with an emoji shortcode at the end' do
          let(:text) { '<p>Beep boop<br />:coolcat:</p>' }

          it 'converts shortcode to image tag' do
            is_expected.to match(/<br><img draggable="false" class="emojione custom-emoji" alt=":coolcat:"/)
          end
        end
      end
    end
  end

  describe 'remote HTML with an invalid IDN anchor' do
    let(:linked_account) do
      Fabricate(
        :account,
        username: 'alice',
        domain: 'valid.example',
        url: 'https://valid.example/users/alice',
        uri: 'https://valid.example/users/alice'
      )
    end
    let(:bad_href) { 'https://broken-idn.example/path' }
    let(:html) { %(<p><a href="#{bad_href}">broken label</a> <a href="#{linked_account.url}">alice</a></p>) }
    let(:status) { Fabricate(:status, account: remote_account, text: html) }

    def stub_normalize(error)
      allow(Addressable::URI).to receive(:parse).and_wrap_original do |method, value|
        uri = method.call(value)
        allow(uri).to receive(:normalize).and_raise(error) if value.to_s == bad_href
        uri
      end
    end

    it 'formats the remote status without raising and keeps the broken anchor' do
      stub_normalize(IDN::Idna::IdnaError.new('Punycode failed (2)'))

      formatted = nil
      expect { formatted = Formatter.instance.format(status) }.not_to raise_error

      fragment = Nokogiri::HTML.fragment(formatted)
      broken = fragment.at_css(%(a[href="#{bad_href}"]))

      expect(broken).not_to be_nil
      expect(broken.text).to eq 'broken label'
      expect(broken['class'].to_s).not_to include('account-url-link')
    end

    it 'keeps decorating a later valid anchor after the IDN failure' do
      stub_normalize(IDN::Idna::IdnaError.new('Punycode failed (2)'))

      fragment = Nokogiri::HTML.fragment(Formatter.instance.format(status))
      valid = fragment.at_css(%(a[href="#{linked_account.url}"]))

      expect(valid).not_to be_nil
      expect(valid['class']).to include('account-url-link')
      expect(valid['data-account-id']).to eq linked_account.id.to_s
      expect(valid.text).to eq 'alice'
    end

    it 'does not rescue unrelated normalize errors' do
      stub_normalize(RuntimeError.new('not an idn error'))

      expect { Formatter.instance.format(status) }.to raise_error(RuntimeError, 'not an idn error')
    end
  end

  describe '#sanitize' do
    let(:html) { '<script>alert("Hello")</script>' }

    subject { Formatter.instance.sanitize(html, Sanitize::Config::MASTODON_STRICT) }

    it 'sanitizes' do
      is_expected.to eq ''
    end
  end

  describe 'compatibility suffixes and trailing hashtags' do
    def formatted_fragment(status)
      Nokogiri::HTML.fragment(Formatter.instance.format(status))
    end

    def expect_before(earlier, later)
      expect(earlier).to be_present
      expect(later).to be_present
      expect(earlier <=> later).to eq(-1)
    end

    def attach_overflow_media(status)
      5.times { Fabricate(:media_attachment, account: status.account, status: status) }
    end

    def add_status_reference(status)
      target = Fabricate(:status, account: local_account, text: 'referenced', uri: nil)
      StatusReference.create!(status: status, target_status: target)
    end

    def remote_hashtag_anchor(name)
      %(<a href="https://remote.test/tags/#{name}" class="mention hashtag" rel="tag">#<span>#{name}</span></a>)
    end

    describe 'with no generated suffix' do
      let(:status) { Fabricate(:status, account: local_account, text: "Hello\n#one #two", uri: nil) }

      it 'keeps the historical HTML' do
        expected = %(<p>Hello<br />#{Formatter.instance.send(:hashtag_html, 'one')} #{Formatter.instance.send(:hashtag_html, 'two')}</p>)

        expect(Formatter.instance.format(status)).to eq(expected)
        expect { Formatter.instance.format(status) }.not_to change { status.reload.text }
      end
    end

    describe 'original media link' do
      it 'places the media link before a trailing hashtag row' do
        status = Fabricate(:status, account: local_account, text: "Hello\n#one #two", uri: nil)
        attach_overflow_media(status)

        fragment = formatted_fragment(status)
        media = fragment.at_css('.original-media-link')
        hashtag = fragment.at_css('a.mention.hashtag')
        separator = fragment.at_css('p > br')

        expect_before(media, separator)
        expect_before(separator, hashtag)
        expect(fragment.at_css('p').children.find { |node| node.text? && node.content.include?('Hello') } <=> media).to eq(-1)
        expect(fragment.css('.original-media-link').size).to eq(1)
        expect(fragment.text).to include('Attached: 5 images')
      end

      it 'places the media link before same-line trailing hashtags' do
        status = Fabricate(:status, account: local_account, text: 'Hello #one #two', uri: nil)
        attach_overflow_media(status)

        fragment = formatted_fragment(status)
        media = fragment.at_css('.original-media-link')
        hashtag = fragment.at_css('a.mention.hashtag')

        expect_before(media, hashtag)
        expect(hashtag.previous&.text?).to be true
        expect(hashtag.previous.content).to match(/[[:space:]]\z/)
      end

      it 'keeps a hashtag-only post ending with the hashtags' do
        status = Fabricate(:status, account: local_account, text: '#one #two', uri: nil)
        attach_overflow_media(status)

        fragment = formatted_fragment(status)
        expect_before(fragment.at_css('.original-media-link'), fragment.at_css('a.mention.hashtag'))
        expect(fragment.css('a').last['class']).to include('hashtag')
      end

      it 'appends without reserializing when the post has no trailing hashtag' do
        status = Fabricate(:status, account: local_account, text: 'Hello', uri: nil)
        attach_overflow_media(status)

        html = Formatter.instance.format(status)

        expect(html).to start_with('<p>Hello<span class="original-media-link"> ')
        expect(html).to end_with('</span></p>')
        expect(html).to include('[Attached: 5 images]')
        expect(html).not_to include('<br')
      end
    end

    describe 'status reference link' do
      it 'places the local reference link before trailing hashtags' do
        status = Fabricate(:status, account: local_account, text: "Hello\n#one #two", uri: nil)
        add_status_reference(status)

        fragment = formatted_fragment(status)
        reference = fragment.at_css('.reference-link-inline')
        hashtag = fragment.at_css('a.mention.hashtag')

        expect_before(reference, fragment.at_css('p > br'))
        expect_before(fragment.at_css('p > br'), hashtag)
        expect(reference.at_css('a')['href']).to include('/references')
        expect(fragment.css('.reference-link-inline').size).to eq(1)
      end

      it 'places a rebuilt remote reference link before trailing hashtags and keeps its URL' do
        html = %(<p>Hello<br>#{remote_hashtag_anchor('one')} #{remote_hashtag_anchor('two')}<span class="reference-link-inline"> <a href="https://example.com/kept-ref">[Ref.]</a></span></p>)
        status = Fabricate(:status, account: remote_account, text: html, url: 'https://remote.test/users/bob/statuses/9')
        add_status_reference(status)

        fragment = formatted_fragment(status)
        reference = fragment.at_css('.reference-link-inline')
        hashtag = fragment.at_css('a.mention.hashtag')

        expect_before(reference, hashtag)
        expect(fragment.css('.reference-link-inline').size).to eq(1)
        expect(reference.at_css('a')['href']).to eq('https://example.com/kept-ref')
        expect(reference.at_css('a')['data-status-id']).to eq(status.id.to_s)
      end

      it 'uses the remote status URL when the HTML has no previous reference link' do
        html = %(<p>Hello<br>#{remote_hashtag_anchor('one')}</p>)
        status = Fabricate(:status, account: remote_account, text: html, url: 'https://remote.test/users/bob/statuses/9')
        add_status_reference(status)

        fragment = formatted_fragment(status)
        reference = fragment.at_css('.reference-link-inline a')

        expect_before(fragment.at_css('.reference-link-inline'), fragment.at_css('a.mention.hashtag'))
        expect(reference['href']).to eq('https://remote.test/users/bob/statuses/9')
      end
    end

    describe 'quote link' do
      it 'places the quote link before trailing hashtags and keeps the QT break' do
        quoted = Fabricate(:status, account: local_account, text: 'quoted', uri: nil)
        status = Fabricate(:status, account: local_account, text: "Hello\n#one #two", uri: nil, quote: quoted)

        fragment = formatted_fragment(status)
        quote = fragment.at_css('.quote-inline')
        hashtag = fragment.at_css('a.mention.hashtag')
        separator = fragment.css('p > br').find { |node| (quote <=> node) == -1 && (node <=> hashtag) == -1 }

        expect_before(quote, hashtag)
        expect(separator).to be_present
        expect(quote.at_css('br')).to be_present
        expect(quote.text).to include('QT:')
        expect(fragment.css('.quote-inline').size).to eq(1)
      end

      it 'places the quote link before same-line trailing hashtags' do
        quoted = Fabricate(:status, account: local_account, text: 'quoted', uri: nil)
        status = Fabricate(:status, account: local_account, text: 'Hello #one #two', uri: nil, quote: quoted)

        fragment = formatted_fragment(status)
        hashtags = fragment.css('a.mention.hashtag')

        expect(hashtags.map { |node| node.text }).to eq(['#one', '#two'])
        expect_before(fragment.at_css('.quote-inline'), hashtags[0])
        expect_before(hashtags[0], hashtags[1])
      end

      it 'keeps the literal QT break when there is no trailing hashtag' do
        quoted = Fabricate(:status, account: local_account, text: 'quoted', uri: nil)
        status = Fabricate(:status, account: local_account, text: 'Hello', uri: nil, quote: quoted)
        html = Formatter.instance.format(status)

        expect(html).to start_with('<p>Hello<span class="quote-inline"><br/>QT:')
        expect(html).to end_with('</span></p>')
      end
    end

    describe 'when quote, media, and reference suffixes are combined' do
      let(:quoted) { Fabricate(:status, account: local_account, text: 'quoted', uri: nil) }
      let(:status) { Fabricate(:status, account: local_account, text: "Hello\n#one #two", uri: nil, quote: quoted) }

      before do
        attach_overflow_media(status)
        add_status_reference(status)
      end

      it 'keeps quote, media, then reference before the trailing hashtags' do
        fragment = formatted_fragment(status)
        quote = fragment.at_css('.quote-inline')
        media = fragment.at_css('.original-media-link')
        reference = fragment.at_css('.reference-link-inline')
        hashtag = fragment.at_css('a.mention.hashtag')

        expect_before(quote, media)
        expect_before(media, reference)
        expect_before(reference, hashtag)
        expect(fragment.css('.quote-inline').size).to eq(1)
        expect(fragment.css('.original-media-link').size).to eq(1)
        expect(fragment.css('.reference-link-inline').size).to eq(1)
        expect(fragment.css('a.mention.hashtag').map { |node| node.text }).to eq(['#one', '#two'])
      end
    end

    describe 'hashtags that are not trailing' do
      it 'does not treat a hashtag followed by text as the suffix boundary' do
        status = Fabricate(:status, account: local_account, text: '#one ordinary-text', uri: nil)
        attach_overflow_media(status)

        fragment = formatted_fragment(status)
        expect_before(fragment.at_css('a.mention.hashtag'), fragment.at_css('.original-media-link'))
        expect(fragment.text).to include('ordinary-text')
        expect(fragment.text.index('ordinary-text')).to be < fragment.text.index('Attached')
      end

      it 'does not treat a hashtag followed by a URL as the suffix boundary' do
        status = Fabricate(:status, account: local_account, text: '#one https://example.com/', uri: nil)
        attach_overflow_media(status)

        fragment = formatted_fragment(status)
        hashtag = fragment.at_css('a.mention.hashtag')
        url = fragment.css('a').find { |node| node['href']&.include?('example.com') }
        media = fragment.at_css('.original-media-link')

        expect_before(hashtag, url)
        expect_before(url, media)
      end

      it 'does not treat a hashtag followed by a comma as the suffix boundary' do
        status = Fabricate(:status, account: local_account, text: '#one ,', uri: nil)
        attach_overflow_media(status)

        fragment = formatted_fragment(status)
        expect_before(fragment.at_css('a.mention.hashtag'), fragment.at_css('.original-media-link'))
        expect(fragment.text).to include(',')
      end

      it 'does not treat a hashtag followed by a mention as the suffix boundary' do
        status = Fabricate(:status, account: local_account, text: '#one @alice', uri: nil)
        attach_overflow_media(status)

        fragment = formatted_fragment(status)
        expect_before(fragment.at_css('a.mention.hashtag'), fragment.at_css('.original-media-link'))
        expect(fragment.text.index('@alice')).to be < fragment.text.index('Attached')
      end
    end

    describe 'quoted, listed, and preformatted endings' do
      def remote_with_reference(html)
        status = Fabricate(:status, account: remote_account, text: html, url: 'https://remote.test/users/bob/statuses/9')
        add_status_reference(status)
        formatted_fragment(status)
      end

      it 'does not place a reference link inside a final blockquote' do
        html = %(<p>Intro</p><blockquote><p>Quoted #{remote_hashtag_anchor('tag')}</p></blockquote>)
        fragment = remote_with_reference(html)
        quote = fragment.at_css('blockquote')

        expect(quote.at_css('.reference-link-inline')).to be_nil
        expect(quote.at_css('a.mention.hashtag').text).to eq('#tag')
        expect(fragment.at_css('.reference-link-inline')).to be_present
      end

      it 'does not append a reference link to a blockquote before a hashtag-only paragraph' do
        html = %(<blockquote><p>Quoted</p></blockquote><p>#{remote_hashtag_anchor('one')} #{remote_hashtag_anchor('two')}</p>)
        fragment = remote_with_reference(html)
        paragraphs = fragment.css('p')
        hashtags = paragraphs.last.css('a.mention.hashtag')

        expect(fragment.at_css('blockquote .reference-link-inline')).to be_nil
        expect(hashtags.map { |node| node.text }).to eq(['#one', '#two'])
        expect_before(fragment.at_css('.reference-link-inline'), hashtags.first)
      end

      it 'does not place a reference link inside a final list item' do
        html = %(<p>Intro</p><ul><li>#{remote_hashtag_anchor('one')}</li></ul>)
        fragment = remote_with_reference(html)

        expect(fragment.at_css('li .reference-link-inline')).to be_nil
        expect(fragment.at_css('li a.mention.hashtag').text).to eq('#one')
        expect(fragment.at_css('.reference-link-inline')).to be_present
      end

      it 'does not place a reference link inside a final preformatted block' do
        html = %(<p>Intro</p><pre>#{remote_hashtag_anchor('one')}</pre>)
        fragment = remote_with_reference(html)

        expect(fragment.at_css('pre .reference-link-inline')).to be_nil
        expect(fragment.at_css('pre a.mention.hashtag').text).to eq('#one')
        expect(fragment.at_css('.reference-link-inline')).to be_present
      end
    end

    describe 'inline wrappers around trailing hashtags' do
      def wrapped_hashtags(names)
        anchors = names.map { |name| remote_hashtag_anchor(name) }.join(' ')
        %(<small>#{anchors}</small>)
      end

      def remote_with_reference(html)
        status = Fabricate(:status, account: remote_account, text: html, url: 'https://remote.test/users/bob/statuses/9')
        add_status_reference(status)
        formatted_fragment(status)
      end

      it 'places quote, media, and reference suffixes before a small hashtag wrapper' do
        quoted = Fabricate(:status, account: local_account, text: 'quoted', uri: nil)
        status = Fabricate(:status, account: local_account, text: 'body', uri: nil, quote: quoted)
        attach_overflow_media(status)
        add_status_reference(status)
        html = %(<p>Hello #{wrapped_hashtags(%w(one two))}</p>)

        fragment = Nokogiri::HTML.fragment(
          Formatter.instance.send(:insert_status_suffixes, html, Formatter.instance.send(:local_status_suffix_fragments, status))
        )
        wrapper = fragment.at_css('small')
        quote = fragment.at_css('.quote-inline')
        media = fragment.at_css('.original-media-link')
        reference = fragment.at_css('.reference-link-inline')

        expect_before(quote, media)
        expect_before(media, reference)
        expect_before(reference, wrapper)
        expect(wrapper.css('.quote-inline, .original-media-link, .reference-link-inline')).to be_empty
        expect(wrapper.css('a.mention.hashtag').map { |node| node.text }).to eq(['#one', '#two'])
        expect(fragment.text.index('Hello')).to be < fragment.text.index('QT:')
      end

      it 'places a remote reference link before hashtags wrapped in small' do
        html = %(<p>Hello #{wrapped_hashtags(%w(one two))}</p>)
        fragment = remote_with_reference(html)
        wrapper = fragment.at_css('small')
        reference = fragment.at_css('.reference-link-inline')

        expect_before(reference, wrapper)
        expect(wrapper.css('.reference-link-inline')).to be_empty
        expect(wrapper.css('a.mention.hashtag').map { |node| node.text }).to eq(['#one', '#two'])
        expect(fragment.text).to include('Hello')
        expect(fragment.text.index('Hello')).to be < fragment.text.index('[Ref.]')
      end

      it 'places a remote reference link before nested inline hashtag wrappers' do
        html = %(<p>Hello <small><span>#{remote_hashtag_anchor('one')}</span> <span>#{remote_hashtag_anchor('two')}</span></small></p>)
        fragment = remote_with_reference(html)
        wrapper = fragment.at_css('small')

        expect_before(fragment.at_css('.reference-link-inline'), wrapper)
        expect(wrapper.css('a.mention.hashtag').map { |node| node.text }).to eq(['#one', '#two'])
      end

      it 'places a remote reference link before a small hashtag group that follows a paragraph' do
        html = %(<p>Hello</p>#{wrapped_hashtags(%w(one two))})
        fragment = remote_with_reference(html)
        paragraph = fragment.at_css('p')
        wrapper = fragment.at_css('small')

        expect(paragraph.at_css('.reference-link-inline')).to be_nil
        expect(paragraph.text).to include('Hello')
        expect_before(fragment.at_css('.reference-link-inline'), wrapper)
        expect(wrapper.css('a.mention.hashtag').map { |node| node.text }).to eq(['#one', '#two'])
      end

      it 'does not treat a small element that contains ordinary text as trailing' do
        html = %(<p>Hello <small>tags: #{remote_hashtag_anchor('one')} #{remote_hashtag_anchor('two')}</small></p>)
        fragment = remote_with_reference(html)
        wrapper = fragment.at_css('small')

        expect_before(wrapper, fragment.at_css('.reference-link-inline'))
        expect(wrapper.text).to include('tags:')
        expect(wrapper.at_css('.reference-link-inline')).to be_nil
      end

      it 'does not treat a wrapper that contains an image as trailing' do
        html = %(<p>Hello <small><img src="https://example.com/a.png">#{remote_hashtag_anchor('one')}</small></p>)
        result = Formatter.instance.send(
          :insert_status_suffixes,
          html,
          ['<span class="reference-link-inline"> <a href="https://example.com/r">[Ref.]</a></span>']
        )
        fragment = Nokogiri::HTML.fragment(result)

        expect_before(fragment.at_css('small'), fragment.at_css('.reference-link-inline'))
        expect(fragment.at_css('small img')).to be_present
        expect(fragment.at_css('small .reference-link-inline')).to be_nil
      end

      it 'does not place a reference link inside a blockquote, list, or pre that wraps hashtags' do
        {
          'blockquote' => %(<blockquote><small>#{remote_hashtag_anchor('one')}</small></blockquote>),
          'li' => %(<ul><li><small>#{remote_hashtag_anchor('one')}</small></li></ul>),
          'pre' => %(<pre><small>#{remote_hashtag_anchor('one')}</small></pre>),
        }.each do |boundary, html|
          fragment = remote_with_reference(html)

          expect(fragment.at_css("#{boundary} .reference-link-inline")).to be_nil
          expect(fragment.at_css("#{boundary} small a.mention.hashtag").text).to eq('#one')
          expect(fragment.at_css('.reference-link-inline')).to be_present
        end
      end
    end

    describe 'paragraph boundaries' do
      it 'keeps a hashtag-only final paragraph after the suffix' do
        status = Fabricate(:status, account: local_account, text: "Hello\n\n#one #two", uri: nil)
        attach_overflow_media(status)

        paragraphs = formatted_fragment(status).css('p')

        expect(paragraphs.size).to eq(2)
        expect(paragraphs[0].at_css('.original-media-link')).to be_present
        expect(paragraphs[0].text).to include('Hello')
        expect(paragraphs[1].at_css('.original-media-link')).to be_nil
        expect(paragraphs[1].css('a.mention.hashtag').map { |node| node.text }).to eq(['#one', '#two'])
      end

      it 'keeps the hashtag row after the line break inside one paragraph' do
        status = Fabricate(:status, account: local_account, text: "Hello\n#one #two", uri: nil)
        attach_overflow_media(status)

        paragraph = formatted_fragment(status).at_css('p')
        media = paragraph.at_css('.original-media-link')
        hashtag = paragraph.at_css('a.mention.hashtag')
        separator = paragraph.css('> br').find { |node| (media <=> node) == -1 && (node <=> hashtag) == -1 }

        expect(paragraph.css('p')).to be_empty
        expect(separator).to be_present
        expect(paragraph.css('a.mention.hashtag').map { |node| node.text }).to eq(['#one', '#two'])
      end
    end

    describe 'blank body' do
      it 'still wraps an overflow media link' do
        status = Fabricate(:status, account: local_account, text: 'placeholder', uri: nil)
        attach_overflow_media(status)
        status.update_column(:text, '')

        html = Formatter.instance.format(status)
        fragment = Nokogiri::HTML.fragment(html)

        expect(html).to start_with('<p><span class="original-media-link"> ')
        expect(html).to end_with('</span></p>')
        expect(fragment.at_css('a.mention.hashtag')).to be_nil
        expect(fragment.text).to include('Attached: 5 images')
      end

      it 'still wraps a reference link' do
        status = Fabricate(:status, account: local_account, text: 'placeholder', uri: nil)
        add_status_reference(status)
        status.update_column(:text, '')

        html = Formatter.instance.format(status)

        expect(html).to start_with('<p><span class="reference-link-inline"> ')
        expect(html).to end_with('</span></p>')
        expect(html).to include('/references')
      end

      it 'stays empty when there is nothing to append' do
        status = Fabricate(:status, account: local_account, text: 'placeholder', uri: nil)
        status.update_column(:text, '')

        expect(Formatter.instance.format(status)).to eq('')
      end
    end

    describe '#add_original_link' do
      it 'keeps appending stored remote content before </p> even after a hashtag' do
        html = '<p>Hello <a class="mention hashtag" rel="tag">#<span>one</span></a></p>'
        result = Formatter.instance.add_original_link(html, 'https://example.com/status', 'Attached: 5 images')
        fragment = Nokogiri::HTML.fragment(result)

        expect_before(fragment.at_css('a.mention.hashtag'), fragment.at_css('a.unhandled-link'))
        expect(result).to end_with('[Attached: 5 images]</a></p>')
      end
    end
  end
end
