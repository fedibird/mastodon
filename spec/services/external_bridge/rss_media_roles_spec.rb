# frozen_string_literal: true

require 'rails_helper'

# Phase 1 of image purpose and author metadata. Synthetic hosts and names only.
RSpec.describe 'External RSS image purpose and author metadata', type: :request do
  let(:user) { Fabricate(:user) }
  let(:other) { Fabricate(:user) }
  let(:png) { Rails.root.join('spec/fixtures/files/emojo.png').binread }

  before { enable_external_bridge_rss!(user, other) }

  def parse(xml)
    ExternalBridge::RSS::Parser.parse!(xml)
  end

  def rss(channel_extra = '', item_extra = '')
    <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:media="http://search.yahoo.com/mrss/"
           xmlns:note="https://note.com">
        <channel>
          <title>Example feed</title>
          <link>https://example.com</link>
          #{channel_extra}
          <item>
            <guid>story</guid>
            <title>Story</title>
            <link>https://example.com/story</link>
            #{item_extra}
          </item>
        </channel>
      </rss>
    XML
  end

  def item
    parse(rss('', yield)).items.first
  end

  describe 'author names' do
    it 'prefers dc:creator, then the core author, then note:creatorName, in any order' do
      orders = [
        '<dc:creator>Ada</dc:creator><author>Grace</author><note:creatorName>Eve</note:creatorName>',
        '<note:creatorName>Eve</note:creatorName><author>Grace</author><dc:creator>Ada</dc:creator>',
      ]
      orders.each do |body|
        story = item { body }
        expect(story.byline).to eq 'Ada'
        expect(story.author_hints['byline_source']).to eq 'dc:creator'
      end

      grace = item { '<author>Grace</author><note:creatorName>Eve</note:creatorName>' }
      expect(grace.byline).to eq 'Grace'
      expect(grace.author_hints['byline_source']).to eq 'rss:author'

      eve = item { '<note:creatorName>Eve</note:creatorName>' }
      expect(eve.byline).to eq 'Eve'
      expect(eve.author_hints['byline_source']).to eq 'note:creatorName'
    end

    it 'accepts another prefix for the same note URI and ignores a different URI or no namespace' do
      story = parse(<<~XML).items.first
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:n="https://note.com" xmlns:fake="https://note.com.evil">
          <channel><title>Example</title><link>https://example.com</link>
            <item>
              <guid>story</guid><title>Story</title><link>https://example.com/story</link>
              <creatorName>Plain</creatorName>
              <fake:creatorName>Wrong URI</fake:creatorName>
              <dc:creatorName>Wrong namespace</dc:creatorName>
              <n:creatorName>Eve</n:creatorName>
            </item>
          </channel>
        </rss>
      XML

      expect(story.byline).to eq 'Eve'
      expect(story.author_hints['byline_source']).to eq 'note:creatorName'
    end

    it 'does not let a blank or markup-only value hide a later name' do
      story = item do
        <<~XML
          <dc:creator>   </dc:creator>
          <dc:creator><![CDATA[<script>Hidden</script>]]></dc:creator>
          <author>  </author>
          <note:creatorName><![CDATA[<b></b>]]></note:creatorName>
          <note:creatorName>Eve</note:creatorName>
        XML
      end

      expect(story.byline).to eq 'Eve'
    end

    it 'cleans markup and control characters and keeps a finite length' do
      long = "#{'A' * 600} tail"
      story = item { "<dc:creator>Ada\u0007 <b>Lovelace</b> #{long}</dc:creator>" }

      expect(story.byline).to start_with('Ada Lovelace A')
      expect(story.byline).not_to include('<')
      expect(story.byline.length).to eq ExternalBridge::RSS::Limits::TITLE_CHARS
    end

    it 'does not inherit a channel creatorName onto an item' do
      story = parse(rss('<note:creatorName>Channel Person</note:creatorName>', '<description>Body</description>')).items.first

      expect(story.byline).to be_nil
      expect(story.author_hints).to eq({})
    end
  end

  describe 'author images' do
    let(:avatar) { 'https://cdn.example/avatars/eve.png' }

    it 'stores a bound hint when the extension name is the displayed byline' do
      story = item { "<note:creatorName>Eve</note:creatorName><note:creatorImage>#{avatar}</note:creatorImage>" }

      expect(story.byline).to eq 'Eve'
      expect(story.author_hints).to include(
        'image_url' => avatar,
        'image_source' => 'note:creatorImage',
        'image_name' => 'Eve',
        'image_bound' => true
      )
      expect(story.media).to eq []
    end

    it 'does not bind the image when the standard author is a different person' do
      story = item do
        <<~XML
          <dc:creator>Ada</dc:creator>
          <note:creatorName>Eve</note:creatorName>
          <note:creatorImage>#{avatar}</note:creatorImage>
        XML
      end

      expect(story.byline).to eq 'Ada'
      expect(story.author_hints['byline_source']).to eq 'dc:creator'
      expect(story.author_hints['image_name']).to eq 'Eve'
      expect(story.author_hints['image_bound']).to be false
    end

    it 'binds the image when both names normalize to the same text' do
      story = item do
        "<dc:creator>Eve</dc:creator><note:creatorName> Eve </note:creatorName><note:creatorImage>#{avatar}</note:creatorImage>"
      end

      expect(story.byline).to eq 'Eve'
      expect(story.author_hints['image_bound']).to be true
    end

    it 'keeps an image-only hint off the byline and out of the gallery' do
      story = item { "<note:creatorImage>#{avatar}</note:creatorImage><description>Body</description>" }

      expect(story.byline).to be_nil
      expect(story.author_hints['image_url']).to eq avatar
      expect(story.author_hints['image_bound']).to be false
      expect(story.author_hints).not_to have_key('image_name')
      expect(story.media).to eq []
    end

    it 'keeps a name when the image URL is rejected' do
      rejected = [
        'javascript:alert(1)',
        'https://user:pass@cdn.example/secret.png',
        'https://cdn.example/token.png?token=abcd',
        'http://127.0.0.1/local.png',
        'http://10.0.0.1/local.png',
        'http://localhost/local.png',
        "https://cdn.example/#{'a' * 2_100}.png",
      ]
      rejected.each do |url|
        story = item { "<note:creatorName>Eve</note:creatorName><note:creatorImage>#{url}</note:creatorImage>" }
        expect(story.byline).to eq 'Eve'
        expect(story.author_hints).not_to have_key('image_url')
      end
    end

    it 'keeps an explicit article image that uses the author URL' do
      story = item do
        <<~XML
          <note:creatorName>Eve</note:creatorName>
          <note:creatorImage>#{avatar}</note:creatorImage>
          <media:content url="#{avatar}" medium="image"/>
          <description><![CDATA[<img src="#{avatar}" width="30" height="30" alt="avatar" class="share">]]></description>
        XML
      end

      expect(story.media.map { |row| [row['origin'], row['url'], row['role']] }).to eq [
        ['media_rss', avatar, 'attachment'],
      ]
      expect(story.media.first).not_to have_key('usage')
      expect(story.author_hints['image_url']).to eq avatar
    end

    it 'does not treat size, shape, filename, or alt text as an avatar or decoration' do
      story = item do
        <<~XML
          <description><![CDATA[
            <img src="https://cdn.example/badge.png" width="30" height="30" alt="avatar" class="avatar share-button">
            <img src="https://cdn.example/pixel.png" width="1" height="1" alt="track">
            <img src="https://cdn.example/mark.png" width="16" height="16" alt="Useful mark">
            <img src="https://cdn.example/tall.png" width="10" height="80" alt="tall">
          ]]></description>
        XML
      end

      expect(story.media.map { |row| row['url'] }).to eq [
        'https://cdn.example/badge.png',
        'https://cdn.example/mark.png',
        'https://cdn.example/tall.png',
      ]
      expect(story.media.map { |row| row['usage'] }.compact).to eq []
      expect(story.author_hints).to eq({})
    end
  end

  describe 'Atom bylines' do
    it 'prefers the entry author name over note:creatorName and does not inherit the feed author' do
      feed = parse(<<~XML)
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:n="https://note.com">
          <title>Atom</title>
          <author><name>Feed Person</name></author>
          <entry>
            <id>urn:with-author</id>
            <title>With</title>
            <author><name>Ada</name></author>
            <n:creatorName>Eve</n:creatorName>
            <n:creatorImage>https://cdn.example/avatars/eve.png</n:creatorImage>
            <updated>2020-01-02T03:04:05Z</updated>
          </entry>
          <entry>
            <id>urn:extension-only</id>
            <title>Extension</title>
            <n:creatorName>Eve</n:creatorName>
            <updated>2020-01-02T03:04:05Z</updated>
          </entry>
          <entry>
            <id>urn:inherited</id>
            <title>Inherited</title>
            <updated>2020-01-02T03:04:05Z</updated>
          </entry>
        </feed>
      XML

      named, extension, inherited = feed.items
      expect(named.byline).to eq 'Ada'
      expect(named.author_hints['byline_source']).to eq 'atom:author'
      expect(named.author_hints['image_bound']).to be false
      expect(extension.byline).to eq 'Eve'
      expect(extension.author_hints['byline_source']).to eq 'note:creatorName'
      expect(inherited.byline).to be_nil
    end
  end

  describe 'poster scope' do
    it 'keeps each group thumbnail on that group and leaves an item image alone' do
      story = item do
        <<~XML
          <media:thumbnail url="https://cdn.example/hero.jpg"/>
          <media:group>
            <media:content url="https://cdn.example/a.mp4" type="video/mp4"/>
            <media:thumbnail url="https://cdn.example/a.jpg"/>
          </media:group>
          <media:group>
            <media:content url="https://cdn.example/b.mp4" type="video/mp4"/>
            <media:thumbnail url="https://cdn.example/b.jpg"/>
          </media:group>
        XML
      end

      videos = story.media.select { |row| row['kind'] == 'video' }
      expect(videos.map { |row| row['poster_url'] }).to eq [
        'https://cdn.example/a.jpg',
        'https://cdn.example/b.jpg',
      ]
      expect(story.media.map { |row| row['url'] }).to include('https://cdn.example/hero.jpg')
      expect(story.media.map { |row| row['url'] }).not_to include('https://cdn.example/a.jpg', 'https://cdn.example/b.jpg')
    end

    it 'does not zip several item thumbnails onto several videos' do
      story = item do
        <<~XML
          <media:thumbnail url="https://cdn.example/first.jpg"/>
          <media:thumbnail url="https://cdn.example/second.jpg"/>
          <media:content url="https://cdn.example/a.mp4" type="video/mp4"/>
          <media:content url="https://cdn.example/b.mp4" type="video/mp4"/>
        XML
      end

      videos = story.media.select { |row| row['kind'] == 'video' }
      expect(videos.map { |row| row['poster_url'] }).to eq [
        'https://cdn.example/first.jpg',
        'https://cdn.example/first.jpg',
      ]
      expect(story.media.select { |row| row['kind'] == 'image' }.map { |row| row['url'] }).to eq [
        'https://cdn.example/second.jpg',
      ]
    end

    it 'lets a content poster outrank a group thumbnail and an item thumbnail' do
      story = item do
        <<~XML
          <media:thumbnail url="https://cdn.example/item.jpg"/>
          <media:group>
            <media:thumbnail url="https://cdn.example/group.jpg"/>
            <media:content url="https://cdn.example/clip.mp4" type="video/mp4">
              <media:thumbnail url="https://cdn.example/content.jpg"/>
            </media:content>
          </media:group>
        XML
      end

      video = story.media.find { |row| row['kind'] == 'video' }
      expect(video['poster_url']).to eq 'https://cdn.example/content.jpg'
      expect(story.media.select { |row| row['kind'] == 'image' }.map { |row| row['url'] }).to eq [
        'https://cdn.example/item.jpg',
        'https://cdn.example/group.jpg',
      ]
    end

    it 'does not copy a channel thumbnail onto the item' do
      story = parse(rss('<media:thumbnail url="https://cdn.example/channel.jpg"/>', '<media:content url="https://cdn.example/clip.mp4" type="video/mp4"/>')).items.first

      expect(story.media.map { |row| row['url'] }).to eq ['https://cdn.example/clip.mp4']
      expect(story.media.first['poster_url']).to be_nil
    end

    it 'keeps audio artwork visible and unlabeled when the association is ambiguous' do
      lone = item do
        <<~XML
          <enclosure url="https://cdn.example/talk.mp3" type="audio/mpeg"/>
          <media:thumbnail url="https://cdn.example/art.jpg"/>
        XML
      end
      art = lone.media.find { |row| row['kind'] == 'image' }
      expect(art['url']).to eq 'https://cdn.example/art.jpg'
      expect(art['role']).to eq 'attachment'
      expect(art['usage']).to eq 'audio_art'
      expect(art['subject_url']).to eq 'https://cdn.example/talk.mp3'
      expect(ExternalBridge::RSS::MediaDigest.hexdigest(lone.media)).to eq(
        ExternalBridge::RSS::MediaDigest.hexdigest(lone.media.map { |row| row.except('usage', 'subject_url') })
      )

      ambiguous = item do
        <<~XML
          <enclosure url="https://cdn.example/one.mp3" type="audio/mpeg"/>
          <enclosure url="https://cdn.example/two.mp3" type="audio/mpeg"/>
          <media:thumbnail url="https://cdn.example/art.jpg"/>
        XML
      end
      image = ambiguous.media.find { |row| row['kind'] == 'image' }
      expect(image['url']).to eq 'https://cdn.example/art.jpg'
      expect(image).not_to have_key('usage')
    end
  end

  describe 'persistence' do
    let(:feed_url) { 'https://feeds.example/roles.xml' }
    let(:avatar) { 'https://cdn.example/avatars/eve.png' }
    let(:image_url) { 'https://cdn.example/story.png' }
    let(:video_url) { 'https://cdn.example/clip.mp4' }

    def document(extra)
      rss('', extra).sub('xmlns:note="https://note.com"', 'xmlns:note="https://note.com"')
    end

    def subscribe_feed(xml)
      stub_request(:get, feed_url).to_return(status: 200, body: xml, headers: { 'Content-Type' => 'application/rss+xml' })
      ExternalBridge::RSS::Subscribe.new.call(user: user, url: feed_url)
      ExternalResource.find_by!(title: 'Story')
    end

    def apply!(xml)
      parsed = parse(xml)
      response = ExternalBridge::RSS::Response.new(code: 200, body: nil, etag: nil, last_modified: nil, final_url: feed_url)
      ExternalBridge::RSS::Ingest.new.apply_public!(ExternalSource.find_by!(canonical_key: feed_url), parsed, response)
    end

    it 'does not fetch an author image or replace the feed actor' do
      xml = document(<<~XML)
        <dc:creator>Ada</dc:creator>
        <note:creatorName>Eve</note:creatorName>
        <note:creatorImage>#{avatar}</note:creatorImage>
        <description><![CDATA[<img src="#{image_url}" alt="Story">]]></description>
      XML
      stub_request(:get, image_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
      resource = subscribe_feed(xml)

      expect(a_request(:get, avatar)).not_to have_been_made
      expect(resource.byline).to eq 'Ada'
      expect(resource.author_hints['image_bound']).to be false
      expect(resource.external_actor.display_name).to eq 'Example feed'
      expect(resource.external_actor.native_id).to eq feed_url
      status = Status.find(ExternalStatusProjection.find_by!(user_id: user.id).status_id)
      expect(status.account_id).to eq user.account_id
      body = owner_json(user, status)
      expect(body.to_json).not_to include(avatar)
      expect(body[:fedibird_external][:byline_name]).to eq 'Ada'
    end

    it 'notifies once for a byline change and does not rebuild media' do
      xml = document(<<~XML)
        <dc:creator>Ada</dc:creator>
        <enclosure url="#{video_url}" type="video/mp4" length="11"/>
        <description><![CDATA[<img src="#{image_url}" alt="Story">]]></description>
      XML
      stub_request(:get, image_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })
      stub_request(:get, video_url).to_return(status: 200, body: 'video', headers: { 'Content-Type' => 'video/mp4', 'Content-Length' => '5' })
      resource = subscribe_feed(xml)
      text_digest = resource.body_digest
      media_revision = resource.media_revision
      marker = ExternalStatusProjection.find_by!(user_id: user.id)
      ExternalBridge::RSS::Subscribe.new.call(user: other, url: feed_url)

      notices = 0
      allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!).and_wrap_original do |method, projection|
        notices += 1
        method.call(projection)
      end
      allow(Rails.cache).to receive(:delete).and_call_original

      apply!(document(<<~XML))
        <dc:creator>Grace</dc:creator>
        <enclosure url="#{video_url}" type="video/mp4" length="11"/>
        <description><![CDATA[<img src="#{image_url}" alt="Story">]]></description>
      XML
      ExternalBridge::RSS::Materialize.new.call(subscription: marker.external_subscription, resources: [resource.reload])
      ExternalBridge::RSS::Materialize.new.call(subscription: ExternalSubscription.find_by!(user_id: other.id), resources: [resource.reload])

      resource.reload
      expect(resource.byline).to eq 'Grace'
      expect(resource.body_digest).to eq text_digest
      expect(resource.revision).to eq text_digest
      expect(resource.media_revision).to eq media_revision
      expect(a_request(:get, video_url)).not_to have_been_made
      expect(a_request(:get, image_url)).to have_been_made.once
      expect(notices).to eq 2
      expect(Rails.cache).to have_received(:delete).with("statuses/#{marker.status_id}").at_least(:once)
      expect(marker.reload.last_seen_byline).to eq 'Grace'
      expect(marker.status.reload.account_id).to eq user.account_id
      expect(Status.find(ExternalStatusProjection.find_by!(user_id: other.id).status_id).account_id).to eq other.account_id

      notices_after = notices
      ExternalBridge::RSS::Materialize.new.call(subscription: marker.external_subscription, resources: [resource.reload])
      expect(notices).to eq notices_after
    end

    it 'does not notify when only the unused author-image hint changes' do
      resource = subscribe_feed(document('<dc:creator>Ada</dc:creator><description>Body</description>'))
      marker = ExternalStatusProjection.find_by!(user_id: user.id)
      notices = 0
      allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!) { notices += 1 }

      apply!(document("<dc:creator>Ada</dc:creator><note:creatorImage>#{avatar}</note:creatorImage><description>Body</description>"))
      ExternalBridge::RSS::Materialize.new.call(subscription: marker.external_subscription, resources: [resource.reload])

      expect(resource.reload.author_hints['image_url']).to eq avatar
      expect(resource.byline).to eq 'Ada'
      expect(notices).to eq 0
      expect(a_request(:get, avatar)).not_to have_been_made
    end

    it 'does not fetch or attach an author or decoration candidate' do
      resource = subscribe_feed(document('<description>Body</description>'))
      resource.update!(
        media_candidates: [
          { 'url' => avatar, 'kind' => 'image', 'role' => 'attachment', 'usage' => 'author', 'position' => 0 },
          { 'url' => 'https://cdn.example/chrome.png', 'kind' => 'image', 'role' => 'attachment', 'usage' => 'decoration', 'position' => 1 },
          { 'url' => image_url, 'kind' => 'image', 'role' => 'attachment', 'position' => 2 },
        ],
        media_revision: 'roles-1'
      )
      stub_request(:get, image_url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })

      ExternalBridge::RSS::Media::Sync.enqueue!(resource, videos: false)

      expect(a_request(:get, avatar)).not_to have_been_made
      expect(a_request(:get, 'https://cdn.example/chrome.png')).not_to have_been_made
      expect(a_request(:get, image_url)).to have_been_made.once
    end

    it 'does not refresh a subscription that is being deleted' do
      resource = subscribe_feed(document('<dc:creator>Ada</dc:creator><description>Body</description>'))
      marker = ExternalStatusProjection.find_by!(user_id: user.id)
      marker.external_subscription.update!(state: 'deleting')
      resource.update!(byline: 'Grace')

      result = ExternalBridge::RSS::Materialize.new.call(subscription: marker.external_subscription.reload, resources: [resource])

      expect(result.ran).to be false
      expect(marker.reload.last_seen_byline).to eq 'Ada'
    end
  end

  def owner_json(owner, status)
    get "/api/v1/statuses/#{status.id}", headers: auth_headers_for(owner)
    expect(response).to have_http_status(200)
    body_as_json
  end
end
