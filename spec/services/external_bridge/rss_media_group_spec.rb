# frozen_string_literal: true

require 'rails_helper'

# Phase 1 of Media RSS groups. Synthetic hosts only. One group is one frame.
# Quality switching and playback fallback are later work.
RSpec.describe 'External RSS media groups' do
  def parse(xml)
    ExternalBridge::RSS::Parser.parse!(xml)
  end

  def item(inner, link: 'https://example.com/story')
    parse(<<~XML).items.first
      <?xml version="1.0"?>
      <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
        <channel>
          <title>Example</title>
          <link>https://example.com</link>
          <item>
            <guid>story</guid>
            <title>Story</title>
            <link>#{link}</link>
            #{inner}
          </item>
        </channel>
      </rss>
    XML
  end

  def urls(story)
    story.media.map { |row| row['url'] }
  end

  def group_for(story)
    story.media.find { |row| row['group'] }['group']
  end

  describe 'representative selection' do
    it 'keeps several qualities and an audio rendition as one audio frame' do
      story = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" medium="video" width="1280" height="720" bitrate="2500000"/>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4" medium="video" width="640" height="360" bitrate="800000"/>
          <media:content url="https://cdn.example/sound.mp4" type="audio/mp4" medium="video" height="0" isDefault="true"/>
        </media:group>
      XML

      frame = story.media.first
      expect(story.media.map { |row| [row['kind'], row['url']] }).to eq [['audio', 'https://cdn.example/sound.mp4']]
      expect(frame['mime_hint']).to eq 'audio/mp4'
      expect(frame).not_to have_key('fallbacks')
      variants = frame['group']['variants']
      expect(variants.map { |row| row['url'] }).to eq [
        'https://cdn.example/high.mp4',
        'https://cdn.example/low.mp4',
        'https://cdn.example/sound.mp4',
      ]
      audio = variants.last
      expect(audio['kind']).to eq 'audio'
      expect(audio['mime']).to eq 'audio/mp4'
      expect(audio['medium']).to eq 'video'
      expect(audio['height']).to eq 0
      expect(audio['is_default']).to be true
      expect(frame['group']['key']).to eq ExternalBridge::RSS::MediaGroup.key_for(variants.map { |row| row['url'] })
    end

    it 'does not treat an omitted height as zero, and does not call a zero-height file audio' do
      omitted = item('<media:content url="https://cdn.example/plain.mp4" type="video/mp4"/>')
      zero = item('<media:group><media:content url="https://cdn.example/flat.mp4" height="0"/></media:group>')
      later = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/flat.mp4" type="video/mp4" height="0" isDefault="true"/>
          <media:content url="https://cdn.example/real.mp4" type="video/mp4"/>
        </media:group>
      XML

      expect(omitted.media.first['kind']).to eq 'video'
      expect(omitted.media.first).not_to have_key('group')
      expect(omitted.media.first['group']).to be_nil
      expect(zero.media).to eq []
      expect(later.media.map { |row| row['url'] }).to eq ['https://cdn.example/real.mp4']
      expect(later.media.first['group']['variants'].map { |row| row['url'] }).to eq ['https://cdn.example/real.mp4']
    end

    it 'uses the first valid default, then full, then document order' do
      defaults = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/a.mp4" type="video/mp4" isDefault="true"/>
          <media:content url="https://cdn.example/b.mp4" type="video/mp4" isDefault="TRUE"/>
        </media:group>
      XML
      false_string = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/a.mp4" type="video/mp4" isDefault="false"/>
          <media:content url="https://cdn.example/b.mp4" type="video/mp4" isDefault="yes"/>
        </media:group>
      XML
      sample = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/sample.mp4" type="video/mp4" expression="sample"/>
          <media:content url="https://cdn.example/full.mp4" type="video/mp4" expression="FULL"/>
          <media:content url="https://cdn.example/live.mp4" type="video/mp4" expression="nonstop"/>
        </media:group>
      XML
      omitted = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/first.mp4" type="video/mp4"/>
          <media:content url="https://cdn.example/second.mp4" type="video/mp4" expression="full"/>
        </media:group>
      XML
      broken_default = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/notes.pdf" type="application/pdf" medium="video" isDefault="true"/>
          <media:content url="https://cdn.example/clip.mp4" type="video/mp4"/>
        </media:group>
      XML

      expect(urls(defaults)).to eq ['https://cdn.example/a.mp4']
      expect(urls(false_string)).to eq ['https://cdn.example/a.mp4']
      expect(false_string.media.first['group']['variants'].map { |row| row['is_default'] }).to eq [false, nil]
      expect(urls(sample)).to eq ['https://cdn.example/full.mp4']
      expect(sample.media.first['group']['variants'].map { |row| row['expression'] }).to eq ['sample', 'full', 'nonstop']
      expect(urls(omitted)).to eq ['https://cdn.example/first.mp4']
      expect(urls(broken_default)).to eq ['https://cdn.example/clip.mp4']
      expect(broken_default.media.first['group']['variants'].map { |row| row['url'] }).to eq ['https://cdn.example/clip.mp4']
    end

    it 'does not rescue an explicit unsupported type, and does not rank by bitrate' do
      rejected = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/clip.mp4" type="application/pdf" medium="video"/>
          <media:content url="https://cdn.example/clip.mp4" medium="document"/>
          <media:content url="https://cdn.example/picture.svg" medium="image"/>
          <media:content url="https://cdn.example/picture.png" type="image/svg+xml" medium="image"/>
          <media:content url="https://cdn.example/run.exe" type="video/mp4" medium="executable"/>
        </media:group>
        <enclosure url="https://cdn.example/talk.mp3" type="audio/mpeg"/>
      XML
      quiet = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4" bitrate="-5" height="999999999"/>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" bitrate="999999999999"/>
        </media:group>
      XML

      expect(rejected.media.map { |row| row['url'] }).to eq ['https://cdn.example/talk.mp3']
      expect(urls(quiet)).to eq ['https://cdn.example/low.mp4']
      variant = quiet.media.first['group']['variants'].first
      expect(variant).not_to have_key('bitrate')
      expect(variant).not_to have_key('height')
    end

    it 'drops a group whose every rendition is unusable and keeps the article' do
      story = item(<<~XML)
        <description>The article is still here</description>
        <media:group>
          <media:content url="https://cdn.example/nope.mp4" type="video/mp4" height="0"/>
          <media:content url="https://cdn.example/nope.pdf" type="application/pdf"/>
        </media:group>
      XML

      expect(story.body).to include('The article is still here')
      expect(story.media).to eq []
    end
  end

  describe 'separate logical media' do
    it 'keeps groups, loose files, an enclosure, and a gallery in document order' do
      story = item(<<~XML)
        <description><![CDATA[
          <img src="https://cdn.example/one.png" alt="One">
          <img src="https://cdn.example/poster.jpg" alt="Poster">
        ]]></description>
        <media:group>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" height="720"/>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4" height="360" isDefault="true"/>
          <media:thumbnail url="https://cdn.example/poster.jpg"/>
        </media:group>
        <media:content url="https://cdn.example/still.jpg" medium="image"/>
        <media:group>
          <media:content url="https://cdn.example/talk.mp3" type="audio/mpeg"/>
          <media:content url="https://cdn.example/talk-hq.mp3" type="audio/mpeg"/>
        </media:group>
        <enclosure url="https://cdn.example/extra.mp3" type="audio/mpeg"/>
      XML

      expect(story.media.map { |row| [row['kind'], row['url'], row['position']] }).to eq [
        ['image', 'https://cdn.example/one.png', 0],
        ['image', 'https://cdn.example/poster.jpg', 1],
        ['video', 'https://cdn.example/low.mp4', 2],
        ['image', 'https://cdn.example/still.jpg', 3],
        ['audio', 'https://cdn.example/talk.mp3', 4],
        ['audio', 'https://cdn.example/extra.mp3', 5],
      ]
      video = story.media.find { |row| row['kind'] == 'video' }
      expect(video['poster_url']).to eq 'https://cdn.example/poster.jpg'
      expect(video['group']['variants'].map { |row| row['url'] }).to eq [
        'https://cdn.example/high.mp4',
        'https://cdn.example/low.mp4',
      ]
      expect(story.media.select { |row| row['origin'] == 'html_img' }.map { |row| row['url'] }).to include('https://cdn.example/poster.jpg')
      expect(story.media.count { |row| row['group'] }).to eq 2
    end

    it 'does not merge groups that share a URL, and does not drop a different file' do
      story = item(<<~XML)
        <enclosure url="https://cdn.example/before.mp4" type="video/mp4"/>
        <media:group>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" isDefault="true"/>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4"/>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4" isDefault="true"/>
        </media:group>
        <enclosure url="https://cdn.example/low.mp4" type="video/mp4"/>
        <enclosure url="https://cdn.example/other.mp3" type="audio/mpeg"/>
        <media:group>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4"/>
          <media:content url="https://cdn.example/side.mp4" type="video/mp4"/>
        </media:group>
        <description><![CDATA[<img src="https://cdn.example/high.mp4" alt="Not a video">]]></description>
      XML

      expect(urls(story)).to eq [
        'https://cdn.example/before.mp4',
        'https://cdn.example/high.mp4',
        'https://cdn.example/other.mp3',
        'https://cdn.example/high.mp4',
        'https://cdn.example/high.mp4',
      ]
      groups = story.media.select { |row| row['group'] }
      expect(groups.first['group']['variants'].map { |row| row['url'] }).to eq [
        'https://cdn.example/high.mp4',
        'https://cdn.example/low.mp4',
      ]
      expect(groups.first['url']).to eq 'https://cdn.example/high.mp4'
      expect(groups.second['group']['key']).not_to eq groups.first['group']['key']
      expect(story.media.last['kind']).to eq 'image'
      expect(story.media.last['origin']).to eq 'html_img'
    end

    it 'keeps two identical groups as two frames with one key' do
      story = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/clip.mp4" type="video/mp4"/>
        </media:group>
        <media:group>
          <media:content url="https://cdn.example/clip.mp4" type="video/mp4"/>
        </media:group>
      XML

      frames = story.media
      expect(frames.map { |row| row['position'] }).to eq [0, 1]
      expect(frames.map { |row| row['group']['key'] }.uniq.size).to eq 1
    end

    it 'accepts another Media RSS prefix and ignores other namespaces' do
      prefixed = parse(<<~XML).items.first
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:m="http://search.yahoo.com/mrss/">
          <channel>
            <title>Example</title><link>https://example.com</link>
            <item>
              <guid>story</guid><title>Story</title><link>https://example.com/story</link>
              <m:group>
                <m:content url="https://cdn.example/clip.mp4" type="video/mp4"/>
                <m:content url="https://cdn.example/small.mp4" type="video/mp4"/>
              </m:group>
            </item>
          </channel>
        </rss>
      XML
      foreign = item(<<~XML)
        <media:group>
          <content url="https://cdn.example/plain.mp4" type="video/mp4"/>
          <other:content xmlns:other="https://other.example/ns" url="https://cdn.example/other.mp4" type="video/mp4"/>
          <media:title>https://cdn.example/title.mp4</media:title>
          <media:description>https://cdn.example/description.mp4</media:description>
          <group>
            <media:content url="https://cdn.example/inside-plain.mp4" type="video/mp4"/>
          </group>
          <media:content>https://cdn.example/text.mp4</media:content>
        </media:group>
      XML

      expect(urls(prefixed)).to eq ['https://cdn.example/clip.mp4']
      expect(prefixed.media.first['group']['variants'].size).to eq 2
      expect(urls(foreign)).to eq ['https://cdn.example/text.mp4']
      expect(foreign.media.to_json).not_to include('plain.mp4', 'other.mp4', 'title.mp4', 'description.mp4', 'inside-plain.mp4')
    end

    it 'treats a nested group as its own frame and keeps its own poster' do
      story = item(<<~XML)
        <media:thumbnail url="https://cdn.example/item.jpg"/>
        <media:group>
          <media:content url="https://cdn.example/outer.mp4" type="video/mp4"/>
          <media:thumbnail url="https://cdn.example/outer.jpg"/>
          <media:group>
            <media:content url="https://cdn.example/inner.mp4" type="video/mp4">
              <media:thumbnail url="https://cdn.example/sibling.jpg"/>
            </media:content>
            <media:content url="https://cdn.example/inner-real.mp4" type="video/mp4" isDefault="true">
              <media:thumbnail url="https://cdn.example/inner.jpg"/>
            </media:content>
          </media:group>
        </media:group>
      XML

      videos = story.media.select { |row| row['kind'] == 'video' }
      expect(videos.map { |row| [row['url'], row['poster_url']] }).to eq [
        ['https://cdn.example/outer.mp4', 'https://cdn.example/outer.jpg'],
        ['https://cdn.example/inner-real.mp4', 'https://cdn.example/inner.jpg'],
      ]
      expect(videos.first['group']['variants'].map { |row| row['url'] }).to eq ['https://cdn.example/outer.mp4']
      expect(videos.second['group']['variants'].map { |row| row['url'] }).to eq [
        'https://cdn.example/inner.mp4',
        'https://cdn.example/inner-real.mp4',
      ]
      expect(urls(story)).to include('https://cdn.example/item.jpg')
      expect(urls(story)).not_to include('https://cdn.example/outer.jpg', 'https://cdn.example/inner.jpg', 'https://cdn.example/sibling.jpg')
    end
  end

  describe 'limits and digests' do
    it 'stores a bounded window that still contains a later default' do
      bodies = (1..10).map do |number|
        default = number == 10 ? ' isDefault="true"' : ''
        %(<media:content url="https://cdn.example/v#{number}.mp4" type="video/mp4"#{default}/>)
      end.join
      story = item("<media:group>#{bodies}</media:group><media:content url=\"https://cdn.example/after.jpg\" medium=\"image\"/>")
      frame = story.media.first
      kept = frame['group']['variants'].map { |row| row['url'] }

      expect(frame['url']).to eq 'https://cdn.example/v10.mp4'
      expect(frame['kind']).to eq 'video'
      expect(kept.size).to eq ExternalBridge::RSS::Limits::MAX_GROUP_VARIANTS
      expect(kept).to include('https://cdn.example/v10.mp4', 'https://cdn.example/v1.mp4')
      expect(kept).not_to include('https://cdn.example/v8.mp4', 'https://cdn.example/v9.mp4')
      expect(story.media.map { |row| row['url'] }).to eq ['https://cdn.example/v10.mp4', 'https://cdn.example/after.jpg']
    end

    it 'stops reading a huge group without dropping the next independent file' do
      stub_const('ExternalBridge::RSS::Limits::MAX_GROUP_SCAN', 3)
      story = item(<<~XML)
        <media:group>
          <media:title>https://cdn.example/title.mp4</media:title>
          <media:content url="https://cdn.example/seen.mp4" type="video/mp4"/>
          <media:content url="https://cdn.example/hidden.mp4" type="video/mp4"/>
        </media:group>
        <enclosure url="https://cdn.example/after.mp3" type="audio/mpeg"/>
      XML

      expect(urls(story)).to eq ['https://cdn.example/seen.mp4', 'https://cdn.example/after.mp3']
    end

    it 'does not enter a group nested past the depth cap' do
      story = item(<<~XML)
        <media:group>
          <media:group>
            <media:group>
              <media:group>
                <media:content url="https://cdn.example/deep.mp4" type="video/mp4"/>
                <media:group>
                  <media:content url="https://cdn.example/too-deep.mp4" type="video/mp4"/>
                </media:group>
              </media:group>
            </media:group>
          </media:group>
        </media:group>
      XML

      expect(urls(story)).to eq ['https://cdn.example/deep.mp4']
    end

    it 'lets one group count as one logical candidate' do
      videos = (1..10).map { |number| %(<media:content url="https://cdn.example/v#{number}.mp4" type="video/mp4"/>) }.join
      images = (1..12).map { |number| %(<media:content url="https://cdn.example/i#{number}.jpg" medium="image"/>) }.join
      story = item("<media:group>#{videos}</media:group>#{images}")

      expect(story.media.size).to eq ExternalBridge::RSS::Limits::MAX_MEDIA_CANDIDATES
      expect(story.media.first['kind']).to eq 'video'
      expect(story.media.first['group']['variants'].size).to eq ExternalBridge::RSS::Limits::MAX_GROUP_VARIANTS
      expect(story.media.count { |row| row['kind'] == 'video' }).to eq 1
      expect(story.media.last['url']).to eq 'https://cdn.example/i11.jpg'
    end

    it 'repeats the same key and digest, and ignores a non-selected rendition change' do
      low = '<media:content url="https://cdn.example/low.mp4" type="video/mp4" bitrate="100"/>'
      story = item(<<~XML)
        <media:group>
          #{low}
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" isDefault="true" bitrate="400"/>
        </media:group>
      XML
      again = item(<<~XML)
        <media:group>
          #{low}
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" isDefault="true" bitrate="400"/>
        </media:group>
      XML
      bitrate = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4" bitrate="250"/>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" isDefault="true" bitrate="400"/>
        </media:group>
      XML
      switched = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4" bitrate="100" isDefault="true"/>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" bitrate="400"/>
        </media:group>
      XML

      expect(again.media).to eq story.media
      expect(ExternalBridge::RSS::MediaDigest.hexdigest(bitrate.media)).to eq ExternalBridge::RSS::MediaDigest.hexdigest(story.media)
      expect(bitrate.media.first['group']['variants'].first['bitrate']).to eq 250
      expect(switched.media.first['url']).to eq 'https://cdn.example/low.mp4'
      expect(switched.media.first['group']['key']).to eq story.media.first['group']['key']
      expect(ExternalBridge::RSS::MediaDigest.hexdigest(switched.media)).not_to eq ExternalBridge::RSS::MediaDigest.hexdigest(story.media)
    end

    it 'stores the group whitelist and still reads a flat candidate' do
      story = item(<<~XML)
        <media:group>
          <media:content url="https://cdn.example/low.mp4" type="video/mp4" width="640" height="360"/>
          <media:content url="https://cdn.example/high.mp4" type="video/mp4" isDefault="true" expression="full"/>
        </media:group>
      XML
      stored = ExternalBridge::RSS::MediaDigest.normalize(story.media)
      expect(stored.first['group']['variants'].map { |row| row['url'] }).to eq [
        'https://cdn.example/low.mp4',
        'https://cdn.example/high.mp4',
      ]
      expect(stored.first['group']['variants'].first['width']).to eq 640
      expect(ExternalBridge::RSS::MediaDigest.hexdigest(stored)).to eq ExternalBridge::RSS::MediaDigest.hexdigest(story.media.map { |row| row.except('group') })

      tampered = story.media.first.deep_dup
      tampered['group']['variants'].first['html'] = '<script>alert(1)</script>'
      tampered['group']['key'] = 'f' * 64
      tampered['note'] = '<b>no</b>'
      cleaned = ExternalBridge::RSS::MediaDigest.normalize([tampered]).first
      expect(cleaned.to_json).not_to include('script', '<b>')
      expect(cleaned).not_to have_key('group')
      expect(cleaned['url']).to eq 'https://cdn.example/high.mp4'

      flat = { 'url' => 'https://cdn.example/old.mp4', 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'position' => 0 }
      expect(ExternalBridge::RSS::MediaDigest.normalize([flat])).to eq [flat]
    end
  end

  describe 'players and posters' do
    let(:link) { 'https://watch.example.com/watch?id=abc123' }

    it 'keeps a group player with that group and still shows a different item player' do
      story = item(<<~XML, link: link)
        <media:group>
          <media:content url="https://cdn.example/a.mp4" type="video/mp4"/>
          <media:player url="https://player.example.com/embed/abc123"/>
          <media:thumbnail url="https://cdn.example/a.jpg"/>
        </media:group>
        <media:group>
          <media:content url="https://cdn.example/b.mp4" type="video/mp4"/>
          <media:thumbnail url="https://cdn.example/b.jpg"/>
        </media:group>
        <media:player url="https://player.example.com/embed/abc123?video_id=abc123"/>
      XML

      expect(story.media.map { |row| [row['kind'], row['origin']] }).to eq [
        ['video', 'media_rss'],
        ['video', 'media_rss'],
        ['embed', 'media_player'],
      ]
      first, second, embed = story.media
      expect(first['poster_url']).to eq 'https://cdn.example/a.jpg'
      expect(second['poster_url']).to eq 'https://cdn.example/b.jpg'
      expect(first['group']['variants'].map { |row| row['kind'] }).to eq %w(video embed)
      expect(second['group']['variants'].map { |row| [row['kind'], row['url']] }).to eq [
        ['video', 'https://cdn.example/b.mp4'],
      ]
      expect(embed['url']).to eq 'https://player.example.com/embed/abc123?video_id=abc123'
      expect(second['group']['variants'].map { |row| row['url'] }).not_to include(embed['url'])
    end

    it 'adopts a media:embed url attribute and a url-less content player only through the resolver' do
      adopted = item(<<~XML, link: link)
        <media:embed url="https://player.example.com/embed/abc123">
          <media:param name="allowscriptaccess">always</media:param>
          <media:param name="flashvars">file=https://cdn.example/secret.mp4</media:param>
        </media:embed>
      XML
      grouped = item(<<~XML, link: link)
        <media:group>
          <media:content medium="video">
            <media:player url="https://player.example.com/embed/abc123"/>
            <media:description>https://cdn.example/not-a-file.mp4</media:description>
          </media:content>
          <media:embed url="https://cdn.example/clip.mp4"/>
          <media:player url="https://evil.example/embed/abc123"/>
        </media:group>
      XML

      expect(adopted.media.map { |row| [row['kind'], row['origin'], row['url']] }).to eq [
        ['embed', 'media_embed', 'https://player.example.com/embed/abc123'],
      ]
      expect(adopted.media.to_json).not_to include('allowscriptaccess', 'flashvars', 'secret.mp4')
      expect(grouped.media.map { |row| [row['kind'], row['origin']] }).to eq [['embed', 'media_player']]
      expect(grouped.media.first['group']['variants'].map { |row| row['url'] }).to eq ['https://player.example.com/embed/abc123']
      expect(grouped.media.flat_map { |row| [row['url'], *Array(row.dig('group', 'variants')).map { |variant| variant['url'] }] }).not_to include(
        'https://cdn.example/not-a-file.mp4',
        'https://evil.example/embed/abc123',
        'https://cdn.example/clip.mp4'
      )
      expect(grouped.media.to_json).not_to include('evil.example', 'clip.mp4')
      expect(grouped.media.first['description']).to eq 'https://cdn.example/not-a-file.mp4'
    end
  end

  describe 'saved representative', type: :request do
    let(:user) { Fabricate(:user) }
    let(:other) { Fabricate(:user) }
    let(:bundle) { external_project_for(user) }
    let(:link) { 'https://watch.example.com/watch?id=abc123' }
    let(:high) { 'https://cdn.example/high.mp4' }
    let(:low) { 'https://cdn.example/low.mp4' }

    before { enable_external_bridge_rss!(user, other) }

    def grouped_item(default_url)
      other_url = default_url == high ? low : high
      item(<<~XML, link: link)
        <media:group>
          <media:content url="#{other_url}" type="video/mp4" bitrate="100"/>
          <media:content url="#{default_url}" type="video/mp4" isDefault="true" bitrate="400"/>
        </media:group>
        <description>Body</description>
      XML
    end

    def store!(story)
      media = ExternalBridge::RSS::MediaDigest.normalize(story.media)
      bundle[:resource].update!(
        canonical_url: link,
        media_candidates: media,
        media_revision: ExternalBridge::RSS::MediaDigest.hexdigest(media)
      )
      bundle[:resource].reload
    end

    it 'reloads the group from the database and leaves a flat row grouped only by a later fetch' do
      resource = store!(grouped_item(high))
      expect(resource.media_candidates.first['group']['key']).to eq group_for(grouped_item(high))['key']
      expect(resource.media_candidates.first['group']['variants'].size).to eq 2

      flat = { 'url' => low, 'kind' => 'video', 'role' => 'attachment', 'origin' => 'enclosure', 'position' => 0 }
      bundle[:resource].update!(media_candidates: [flat], media_revision: ExternalBridge::RSS::MediaDigest.hexdigest([flat]))
      expect(bundle[:resource].reload.media_candidates).to eq [flat]
    end

    it 'shows and fetches only the representative' do
      resource = store!(grouped_item(high))
      high_digest = ExternalBridge::RSS::MediaDigest.url_digest(high)
      low_digest = ExternalBridge::RSS::MediaDigest.url_digest(low)
      marker = bundle[:marker].reload
      sequence = ExternalBridge::RSS::Media::Sequence.for(marker)
      remote = ExternalBridge::RSS::Media::RemotePayload.for(marker)

      expect(resource.media_candidates.map { |row| [row['kind'], row['url']] }).to eq [['video', high]]
      expect(bundle[:marker].reload.external_resource.media_candidates.map { |row| row['url'] }).to eq [high]
      expect(sequence.map { |row| row[:url] }).to eq [high]
      expect(sequence.map { |row| row[:id] }).to eq ["rss-media:#{high_digest[0, 16]}"]
      expect(remote.map { |row| row[:url] }).to eq [high]
      expect(sequence.to_json).not_to include(low)
      expect(ExternalBridge::RSS::Media::CandidateLookup.for_fetch(resource.media_candidates, low_digest)).to be_nil
      expect(ExternalBridge::RSS::Media::CandidateLookup.for_fetch(resource.media_candidates, high_digest)['url']).to eq high

      ExternalBridge::RSS::Media::Fetch.new.call(resource.id, resource.media_revision, low_digest)
      expect(a_request(:get, low)).not_to have_been_made
      expect(a_request(:head, low)).not_to have_been_made
      expect(ExternalMediaAsset.where(url_digest: low_digest)).to be_empty

      Setting.external_bridge_rss_video_policy = 'hybrid'
      allow(ExternalBridge::RSS::MediaFetchWorker).to receive(:perform_async)
      ExternalBridge::RSS::Media::Sync.enqueue!(resource, videos: true)
      expect(ExternalBridge::RSS::MediaFetchWorker).to have_received(:perform_async).with(resource.id, resource.media_revision, high_digest)
      expect(ExternalBridge::RSS::MediaFetchWorker).not_to have_received(:perform_async).with(resource.id, resource.media_revision, low_digest)
    ensure
      Setting.external_bridge_rss_video_policy = 'remote'
    end

    it 'does not fetch a replaced representative from an old job or attach a ready alternate' do
      resource = store!(grouped_item(high))
      old_revision = resource.media_revision
      old_digest = ExternalBridge::RSS::MediaDigest.url_digest(high)
      low_digest = ExternalBridge::RSS::MediaDigest.url_digest(low)
      store!(grouped_item(low))

      ExternalBridge::RSS::Media::Fetch.new.call(resource.id, old_revision, old_digest)
      ExternalBridge::RSS::Media::Fetch.new.call(bundle[:resource].id, bundle[:resource].media_revision, old_digest)
      expect(a_request(:get, high)).not_to have_been_made
      expect(a_request(:head, high)).not_to have_been_made
      expect(ExternalMediaAsset.count).to eq 0

      asset = ExternalMediaAsset.create!(url_digest: high_digest_for_ready, kind: 'video', state: 'failed')
      ExternalBridge::RSS::Media::AssetResource.link!(asset.id, bundle[:resource].id)
      ExternalBridge::RSS::Media::Sync.attach_ready!(bundle[:marker], bundle[:resource].reload)
      expect(ExternalMediaAssetResource.where(external_media_asset_id: asset.id, external_resource_id: bundle[:resource].id)).to be_empty
      expect(ExternalMediaAsset.find_by(url_digest: asset.url_digest)).to be_present
      expect(ExternalBridge::RSS::Media::Sequence.for(bundle[:marker].reload).map { |row| row[:url] }).to eq [low]
      expect(low_digest).not_to eq old_digest
    end

    it 'keeps the same resource, revision, and group key when the feed is stored again' do
      feed_url = bundle[:source].canonical_key
      xml = <<~XML
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel>
            <title>Example</title>
            <link>https://example.com</link>
            <item>
              <guid>guid-external</guid>
              <title>External title</title>
              <link>#{link}</link>
              <description>Body</description>
              <media:group>
                <media:content url="#{low}" type="video/mp4" bitrate="100"/>
                <media:content url="#{high}" type="video/mp4" isDefault="true"/>
              </media:group>
            </item>
          </channel>
        </rss>
      XML
      stub_request(:get, feed_url).to_return(status: 200, body: xml, headers: { 'Content-Type' => 'application/rss+xml' })
      parsed = parse(xml)
      ExternalBridge::RSS::HttpClient
      feed_response = ExternalBridge::RSS::Response.new(code: 200, body: nil, etag: nil, last_modified: nil, final_url: feed_url)
      ExternalBridge::RSS::Ingest.new.apply_public!(bundle[:source], parsed, feed_response)
      resource = ExternalResource.find_by!(canonical_key: bundle[:resource].canonical_key)
      revision = resource.media_revision
      key = resource.media_candidates.first['group']['key']
      ExternalBridge::RSS::Ingest.new.apply_public!(bundle[:source], parse(xml), feed_response)

      resource.reload
      expect(resource.id).to eq bundle[:resource].id
      expect(resource.media_revision).to eq revision
      expect(resource.media_candidates.first['group']['key']).to eq key
      expect(resource.media_candidates.first['url']).to eq high

      bitrate_xml = xml.sub('bitrate="100"', 'bitrate="250"')
      ExternalBridge::RSS::Ingest.new.apply_public!(bundle[:source], parse(bitrate_xml), feed_response)
      resource.reload
      expect(resource.media_revision).to eq revision
      expect(resource.media_candidates.first['group']['variants'].first['bitrate']).to eq 250

      get "/api/v1/statuses/#{bundle[:status].id}", headers: auth_headers_for(user)
      expect(response).to have_http_status(200)
      body = body_as_json
      expect(body[:fedibird_external][:sequence].map { |row| row[:url] }).to eq [high]
      expect(body.to_json).not_to include(low)

      get "/api/v1/statuses/#{bundle[:status].id}", headers: auth_headers_for(other)
      expect(response.body).not_to include(low)
      expect(response.body).not_to include(high)
    end

    def high_digest_for_ready
      ExternalBridge::RSS::MediaDigest.url_digest(high)
    end
  end
end
