# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::ProcessStatusUpdateService, type: :service do # rubocop:disable Metrics/BlockLength
  subject { described_class.new }

  let(:remote_account) do
    Fabricate(
      :account,
      username: 'alice',
      domain: 'example.com',
      protocol: :activitypub,
      uri: 'https://example.com/users/alice',
      inbox_url: 'https://example.com/users/alice/inbox'
    )
  end
  let!(:status) { Fabricate(:status, text: 'Hello world', account: remote_account, uri: 'https://example.com/users/alice/statuses/1') }
  let(:payload) do
    {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: status.uri,
      type: 'Note',
      summary: 'Show more',
      content: 'Hello universe',
      updated: '2021-09-08T22:39:25Z',
      tag: [
        { type: 'Hashtag', name: 'hoge' },
        { type: 'Mention', href: ActivityPub::TagManager.instance.uri_for(alice) },
      ],
    }
  end
  let(:json) { Oj.load(Oj.dump(payload)) }
  let(:alice) { Fabricate(:account, username: 'mentioned') }
  let(:bob) { Fabricate(:account, username: 'other') }
  let(:mentions) { [] }
  let(:tags) { [] }

  def poll_option_json(name, votes)
    { type: 'Note', name: name, replies: { type: 'Collection', totalItems: votes } }
  end

  def attach_remote_media(record, url, **attrs)
    media = MediaAttachment.new({ account: record.account, status: record, remote_url: url }.merge(attrs))
    media.save!(validate: false)
    media
  end

  def attach_poll(record, options: %w(Foo Bar), expires_at: 10.days.from_now.utc, tallies: nil)
    poll = Poll.create!(
      account: record.account,
      status: record,
      options: options,
      multiple: false,
      expires_at: expires_at,
      cached_tallies: tallies || Array.new(options.size, 0)
    )
    record.update!(poll_id: poll.id)
    poll
  end

  before do
    mentions.each { |account| Fabricate(:mention, status: status, account: account) }
    tags.each { |tag| status.tags << tag }
    allow(DistributionWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_in)
    allow(ActivityPub::LowPriorityDeliveryWorker).to receive(:push_bulk)
    allow(ActivityPub::ForwardDistributionWorker).to receive(:perform_async)
    allow(PollExpirationNotifyWorker).to receive(:perform_at)
    allow(PollExpirationNotifyWorker).to receive(:remove_from_scheduled)
  end

  describe '#call' do # rubocop:disable Metrics/BlockLength
    it 'updates text, spoiler, sensitive, and language' do
      payload[:sensitive] = true
      payload[:contentMap] = { ja: 'Hello universe' }
      payload[:content] = '<p>Hello universe</p>'

      subject.call(status, json, json)

      status.reload
      expect(status.text).to eq '<p>Hello universe</p>'
      expect(status.spoiler_text).to eq 'Show more'
      expect(status.sensitive).to be true
      expect(status.language).to eq 'ja'
    end

    it 'renders markdown and Misskey markdown source the way Create does' do
      payload.delete(:content)
      payload[:source] = { content: '**bold** %{domain}', mediaType: 'text/markdown' }

      subject.call(status, json, json)

      expect(status.reload.text).to include('<strong>bold</strong>')
      expect(status.text).to include(Rails.configuration.x.local_domain)

      payload[:source] = { content: 'misskey %{domain}', mediaType: 'text/x.misskeymarkdown' }
      payload[:updated] = '2021-09-09T22:39:25Z'
      refreshed = Oj.load(Oj.dump(payload))
      subject.call(status.reload, refreshed, refreshed)

      expect(status.reload.text).to include('misskey')
      expect(status.text).to include(Rails.configuration.x.local_domain)
    end

    it 'falls back to language detection when no language map is present' do
      allow(LanguageDetector.instance).to receive(:detect).and_return('en')

      subject.call(status, json, json)

      expect(status.reload.language).to eq 'en'
      expect(LanguageDetector.instance).to have_received(:detect)
    end

    it 'adds an original-media link when the payload exceeds the attachment cap' do
      previous = Setting.attachments_max
      Setting.attachments_max = 1
      payload[:content] = '<p>Hello universe</p>'
      payload[:attachment] = [
        { type: 'Image', mediaType: 'image/png', url: 'https://example.com/one.png' },
        { type: 'Image', mediaType: 'image/png', url: 'https://example.com/two.png' },
      ]

      subject.call(status, json, json)

      expect(status.reload.text).to include('original-media-link')
      expect(status.ordered_media_attachments.map(&:remote_url)).to eq %w(https://example.com/one.png)
    ensure
      Setting.attachments_max = previous
    end

    context 'when the changes are only in sanitized-out HTML' do
      let!(:status) do
        Fabricate(
          :status,
          text: '<p>Hello world <a href="https://joinmastodon.org" rel="nofollow">joinmastodon.org</a></p>',
          account: remote_account,
          uri: 'https://example.com/users/alice/statuses/sanitized'
        )
      end
      let(:payload) do
        {
          id: status.uri,
          type: 'Note',
          updated: '2021-09-08T22:39:25Z',
          content: '<p>Hello world <a href="https://joinmastodon.org" rel="noreferrer">joinmastodon.org</a></p>',
        }
      end

      before { subject.call(status, json, json) }

      it 'does not create any edits' do
        expect(status.reload.edits).to be_empty
      end

      it 'does not mark status as edited' do
        expect(status.edited?).to be false
      end
    end

    context 'when the status has not been explicitly edited' do
      let(:payload) do
        {
          id: status.uri,
          type: 'Note',
          content: 'Updated text',
        }
      end

      before { subject.call(status, json, json) }

      it 'does not create edits, mark the status edited, or change the text' do
        status.reload
        expect(status.edits).to be_empty
        expect(status.edited?).to be false
        expect(status.text).to eq 'Hello world'
      end
    end

    context 'when a Question update has no updated timestamp' do
      let!(:expiration) { 10.days.from_now.utc.change(usec: 0) }
      let(:payload) do
        {
          id: status.uri,
          type: 'Question',
          content: 'Changed text',
          endTime: 2.days.from_now.utc.iso8601,
          votersCount: 7,
          oneOf: [
            poll_option_json('Foo', 4),
            poll_option_json('Bar', 3),
          ],
        }
      end

      before { attach_poll(status, expires_at: expiration) }

      it 'refreshes tallies, voters, and expiration without editing the status' do
        subject.call(status, json, json)

        status.reload
        expect(status.edits).to be_empty
        expect(status.edited?).to be false
        expect(status.text).to eq 'Hello world'
        expect(status.poll.cached_tallies).to eq [4, 3]
        expect(status.poll.voters_count).to eq 7
        expect(status.poll.expires_at).to be_within(1.second).of(Time.zone.parse(payload[:endTime]))
      end
    end

    context 'when an implicit Question update changes poll options' do
      let(:payload) do
        {
          id: status.uri,
          type: 'Question',
          content: 'Hello world',
          endTime: 10.days.from_now.utc.iso8601,
          oneOf: [
            poll_option_json('Foo', 4),
            poll_option_json('Bar', 3),
            poll_option_json('Baz', 3),
          ],
        }
      end

      before { attach_poll(status) }

      it 'does not apply the structural poll change or the text' do
        subject.call(status, json, json)

        status.reload
        expect(status.edits).to be_empty
        expect(status.edited?).to be false
        expect(status.text).to eq 'Hello world'
        expect(status.poll.options).to eq %w(Foo Bar)
        expect(status.poll.cached_tallies).to eq [0, 0]
      end
    end

    context 'when receiving an edit older than the latest processed' do
      before do
        status.snapshot!(at_time: status.created_at, rate_limit: false)
        status.update!(text: 'Hello newer world', edited_at: Time.now.utc)
        status.snapshot!(rate_limit: false)
      end

      it 'does not create edits or change text, spoiler, or edited_at' do
        expect { subject.call(status, json, json) }.to_not(change { status.reload.edits.pluck(:id) })
        expect(status.reload.text).to eq 'Hello newer world'
        expect(status.spoiler_text).to eq ''
      end
    end

    context 'with no changes at all' do
      let(:payload) { { id: status.uri, type: 'Note', content: 'Hello world' } }

      it 'does not create edits or broadcast' do
        subject.call(status, json, json)

        expect(status.reload.edits).to be_empty
        expect(status.edited?).to be false
        expect(DistributionWorker).to_not have_received(:perform_async)
      end
    end

    context 'with no changes and originally with no ordered_media_attachment_ids' do
      let(:payload) { { id: status.uri, type: 'Note', content: 'Hello world' } }

      before { status.update!(ordered_media_attachment_ids: nil) }

      it 'does not create edits' do
        subject.call(status, json, json)

        expect(status.reload.edits).to be_empty
        expect(status.edited?).to be false
        expect(status.ordered_media_attachment_ids).to be_nil
      end
    end

    it 'replaces tags' do
      status.tags << Fabricate(:tag, name: 'test')
      subject.call(status, json, json)

      expect(status.tags.reload.map(&:name)).to eq %w(hoge)
    end

    it 'adds a mention and silences one that was removed' do
      Fabricate(:mention, status: status, account: alice)
      Fabricate(:mention, status: status, account: bob)

      subject.call(status, json, json)

      expect(status.active_mentions.reload.map(&:account_id)).to eq [alice.id]
      expect(status.mentions.find_by(account: bob).silent).to be true
    end

    it 'records a moderation signal only for a newly explicit local mention' do
      Fabricate(:mention, status: status, account: bob)
      parent = Fabricate(:status, account: alice)
      status.update!(in_reply_to_id: parent.id, in_reply_to_account_id: alice.id, reply: true)
      carol = Fabricate(:account, username: 'carol')
      payload[:tag] = [
        { type: 'Mention', href: ActivityPub::TagManager.instance.uri_for(alice) },
        { type: 'Mention', href: ActivityPub::TagManager.instance.uri_for(bob) },
        { type: 'Mention', href: ActivityPub::TagManager.instance.uri_for(carol) },
      ]

      expect { subject.call(status, json, json) }.to change(ModerationInteractionEvent, :count).by(1)

      event = ModerationInteractionEvent.order(:id).last
      expect(event.event_type).to eq 'mention'
      expect(event.target_subject.account_id).to eq carol.id
      expect { subject.call(status.reload, json, json) }.to_not change(ModerationInteractionEvent, :count)
    end

    context 'when originally without media attachments' do
      let(:payload) do
        {
          id: status.uri,
          type: 'Note',
          content: 'Hello universe',
          updated: '2021-09-08T22:39:25Z',
          attachment: [
            { type: 'Image', mediaType: 'image/png', url: 'https://example.com/foo.png', thumbhash: 'thumb-1' },
          ],
        }
      end

      before do
        stub_request(:get, 'https://example.com/foo.png').to_return(body: attachment_fixture('emojo.png'), headers: { 'Content-Type' => 'image/png' })
        subject.call(status, json, json)
      end

      it 'stores the attachment, thumbhash, and edit without truncating below the cap' do
        media = status.reload.ordered_media_attachments.first

        expect(media.remote_url).to eq 'https://example.com/foo.png'
        expect(media.thumbhash).to eq 'thumb-1'
        expect(a_request(:get, 'https://example.com/foo.png')).to have_been_made
        expect(status.edits.reload.last.ordered_media_attachment_ids).to eq [media.id]
      end
    end

    context 'when originally with media attachments' do
      let(:payload) do
        {
          id: status.uri,
          type: 'Note',
          content: 'Hello universe',
          updated: '2021-09-08T22:39:25Z',
          attachment: [
            { type: 'Image', mediaType: 'image/png', url: 'https://example.com/bar.png', name: 'Second' },
            { type: 'Image', mediaType: 'image/png', url: 'https://example.com/foo.png', name: 'A picture', blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj', focalPoint: [0.1, -0.2] },
          ],
        }
      end

      before do
        attach_remote_media(status, 'https://example.com/foo.png')
        attach_remote_media(status, 'https://example.com/unused.png')
        attach_remote_media(status, 'https://example.com/bar.png')
        allow(RedownloadMediaWorker).to receive(:perform_in)
        subject.call(status, json, json)
      end

      it 'updates metadata, reorders, and drops media missing from the payload' do
        urls = status.reload.ordered_media_attachments.map(&:remote_url)

        expect(urls).to eq %w(https://example.com/bar.png https://example.com/foo.png)
        kept = status.ordered_media_attachments.last
        expect(kept.description).to eq 'A picture'
        expect(kept.blurhash).to eq 'LEHV6nWB2yk8pyo0adR*.7kCMdnj'
        expect(kept.focus).to eq '0.1,-0.2'
        expect(RedownloadMediaWorker).to_not have_received(:perform_in)
        expect(status.edits.reload.last.ordered_media_attachment_ids).to eq status.ordered_media_attachment_ids
      end
    end

    it 'keeps an existing set larger than four and larger than a lowered cap' do
      previous = Setting.attachments_max
      Setting.attachments_max = 4
      urls = (1..6).map { |index| "https://example.com/keep-#{index}.png" }
      urls.each { |url| attach_remote_media(status, url) }
      payload[:attachment] = urls.map { |url| { type: 'Image', mediaType: 'image/png', url: url } }

      subject.call(status, json, json)

      expect(status.reload.ordered_media_attachments.map(&:remote_url)).to eq urls
    ensure
      Setting.attachments_max = previous
    end

    it 'does not clear media when the attachment key is omitted' do
      attach_remote_media(status, 'https://example.com/keep.png')
      payload.delete(:attachment)

      subject.call(status, json, json)

      expect(status.reload.media_attachments.map(&:remote_url)).to eq %w(https://example.com/keep.png)
    end

    it 'skips an attachment whose URI scheme is unsupported' do
      payload[:attachment] = [
        { type: 'Image', url: 'javascript:alert(1)' },
        { type: 'Image', mediaType: 'image/png', url: 'https://example.com/ok.png' },
      ]

      subject.call(status, json, json)

      expect(status.reload.ordered_media_attachments.map(&:remote_url)).to eq %w(https://example.com/ok.png)
    end

    context 'when originally with a poll' do
      before do
        attach_poll(status)
        subject.call(status, json, json)
      end

      it 'removes the poll and records that in history' do
        expect(status.reload.poll).to be_nil
        expect(status.edits.reload.last.poll_options).to be_nil
      end
    end

    context 'when originally without a poll' do
      let(:payload) do
        {
          id: status.uri,
          type: 'Question',
          content: 'Hello universe',
          updated: '2021-09-08T22:39:25Z',
          closed: true,
          oneOf: [
            { type: 'Note', name: 'Foo' },
            { type: 'Note', name: 'Bar' },
            { type: 'Note', name: 'Baz' },
          ],
        }
      end

      before { subject.call(status, json, json) }

      it 'creates a poll and records its options' do
        expect(status.reload.poll.options).to eq %w(Foo Bar Baz)
        expect(status.edits.reload.last.poll_options).to eq %w(Foo Bar Baz)
      end
    end

    it 'creates edit history and sets edited_at' do
      subject.call(status, json, json)

      expect(status.edits.reload.map(&:text)).to eq ['Hello world', 'Hello universe']
      expect(status.reload.edited_at).to be_within(1.second).of(Time.utc(2021, 9, 8, 22, 39, 25))
    end

    it 'resets preview cards and broadcasts status.update only for a real edit' do
      card = PreviewCard.create!(url: 'https://example.com/preview', title: 'Preview')
      status.preview_cards << card

      subject.call(status, json, json)

      expect(status.reload.preview_cards).to be_empty
      expect(LinkCrawlWorker).to have_received(:perform_in).with(kind_of(ActiveSupport::Duration), status.id)
      expect(DistributionWorker).to have_received(:perform_async).with(status.id, 'update' => true)
    end

    it 'strips only the stored quote compatibility link and keeps a different URL' do
      quoted = Fabricate(:status, account: remote_account, uri: 'https://misskey.example/notes/abc', url: 'https://misskey.example/notes/abc')
      other = 'https://other.example/notes/zzz'
      status.update!(quote_id: quoted.id, text: %(<p>Hello<br><br>RE: <a href="#{quoted.url}">#{quoted.url}</a> #{other}</p>))
      payload[:content] = %(<p>Hello universe<br><br>RE: <a href="#{quoted.url}">#{quoted.url}</a> <a href="#{other}">#{other}</a></p>)
      payload[:_misskey_quote] = quoted.uri

      subject.call(status, json, json)

      status.reload
      expect(status.quote_id).to eq quoted.id
      expect(status.text).to include(other)
      expect(status.text).to_not include("RE: <a href=\"#{quoted.url}\"")
    end

    it 'leaves Fedibird relationship fields unchanged' do
      quoted = Fabricate(:status, uri: 'https://example.com/users/bob/statuses/9', url: 'https://example.com/users/bob/statuses/9', account: Fabricate(:account, domain: 'example.com', username: 'bob'))
      parent = Fabricate(:status)
      conversation = Conversation.create!(uri: nil)
      generator = Generator.new(uri: 'https://example.com/apps/1', name: 'Fedibird', type: :Application, website: 'https://example.com')
      generator.save!(validate: false)
      referenced = Fabricate(:status)
      StatusReference.create!(status: status, target_status: referenced)
      status.update!(
        visibility: :unlisted,
        searchability: :private,
        in_reply_to_id: parent.id,
        in_reply_to_account_id: parent.account_id,
        reply: true,
        conversation_id: conversation.id,
        quote_id: quoted.id,
        generator_id: generator.id
      )
      StatusExpire.create!(status: status, expires_at: 3.days.from_now, action: :mark)
      payload[:to] = [ActivityPub::TagManager::COLLECTIONS[:public]]
      payload[:inReplyTo] = 'https://example.com/users/someone/statuses/2'
      payload[:quoteUri] = 'https://example.com/users/someone/statuses/3'
      payload[:expiry] = 1.hour.from_now.iso8601
      payload[:generator] = { type: 'Application', name: 'Other', id: 'https://other.example/app' }
      payload[:searchableBy] = 'https://example.com/followers'

      subject.call(status, json, json)

      status.reload
      expect(status.visibility).to eq 'unlisted'
      expect(status.searchability).to eq 'private'
      expect(status.in_reply_to_id).to eq parent.id
      expect(status.in_reply_to_account_id).to eq parent.account_id
      expect(status.conversation_id).to eq conversation.id
      expect(status.quote_id).to eq quoted.id
      expect(status.generator_id).to eq generator.id
      expect(status.references.map(&:id)).to eq [referenced.id]
      expect(status.status_expire.action).to eq 'mark'
    end

    it 'merges custom emoji metadata without dropping fields the tag omits' do
      stub_request(:get, 'https://example.com/emoji.png').to_return(body: attachment_fixture('emojo.png'), headers: { 'Content-Type' => 'image/png' })
      stub_request(:get, 'https://example.com/emoji-2.png').to_return(body: attachment_fixture('emojo.png'), headers: { 'Content-Type' => 'image/png' })
      emoji = CustomEmoji.create!(
        shortcode: 'blob',
        domain: remote_account.domain,
        image_remote_url: 'https://example.com/emoji.png',
        license: 'CC BY 4.0',
        category: nil
      )
      emoji.org_category = 'cute'
      emoji.misskey_license = 'free'
      emoji.aliases = ['blobcat']
      emoji.save!

      payload[:tag] = [
        {
          id: 'https://example.com/emojis/blob',
          type: 'Emoji',
          name: ':blob:',
          icon: { type: 'Image', url: 'https://example.com/emoji-2.png' },
          keywords: ['blobcat', 'cat'],
          license: 'Apache-2.0',
        },
      ]

      subject.call(status, json, json)

      emoji.reload
      expect(emoji.image_remote_url).to eq 'https://example.com/emoji-2.png'
      expect(emoji.license).to eq 'Apache-2.0'
      expect(emoji.aliases).to include('blobcat')
      expect(emoji.org_category).to eq 'cute'
      expect(emoji.misskey_license).to eq 'free'
    end

    it 'rejects a whole explicit update that matches reject_pattern or reject_blurhash' do
      previous_pattern = Setting.reject_pattern
      previous_blurhash = Setting.reject_blurhash
      attach_remote_media(status, 'https://example.com/foo.png', description: 'kept')
      blurhash = 'LEHV6nWB2yk8pyo0adR*.7kCMdnj'

      Setting.reject_pattern = 'forbidden-phrase'
      expect { subject.call(status, json, json_with(content: 'a forbidden-phrase')) }.to raise_error(Mastodon::RejectPayload)
      expect(status.reload.text).to eq 'Hello world'
      expect(status.edits).to be_empty
      expect(status.edited_at).to be_nil

      expect { subject.call(status, json, json_with(attachment: [{ type: 'Image', url: 'https://example.com/foo.png', name: 'forbidden-phrase' }])) }.to raise_error(Mastodon::RejectPayload)
      expect(status.reload.media_attachments.first.description).to eq 'kept'

      Setting.reject_pattern = ''
      Setting.reject_blurhash = blurhash
      expect do
        subject.call(status, json, json_with(attachment: [{ type: 'Image', url: 'https://example.com/foo.png', blurhash: blurhash }]))
      end.to raise_error(Mastodon::RejectPayload)

      expect(status.reload.text).to eq 'Hello world'
      expect(status.edited_at).to be_nil
      expect(status.edits).to be_empty
      expect(status.media_attachments.first.blurhash).to be_nil
      expect(DistributionWorker).to_not have_received(:perform_async)
    ensure
      Setting.reject_pattern = previous_pattern
      Setting.reject_blurhash = previous_blurhash
    end

    it 'forwards a signed edit to local reblogger, reply, and group followers' do
      group = Fabricate(:account, username: 'localsquad', actor_type: 'Group')
      parent_author = Fabricate(:account, username: 'author')
      parent = Fabricate(:status, account: parent_author, visibility: :public)
      status.update!(in_reply_to_id: parent.id, in_reply_to_account_id: parent_author.id, reply: true, visibility: :public)
      Fabricate(:status, account: group, reblog: status, visibility: :public)
      group_follower = remote_follower('groupfan', 'https://group.example/users/groupfan/inbox')
      reply_follower = remote_follower('reader', 'https://reader.example/users/reader/inbox')
      group_follower.follow!(group)
      reply_follower.follow!(parent_author)
      activity = signed_activity

      subject.call(status, activity, json)

      expect(ActivityPub::LowPriorityDeliveryWorker).to have_received(:push_bulk).with(
        include('https://group.example/users/groupfan/inbox', 'https://reader.example/users/reader/inbox'),
        limit: 1_000
      )
    end

    it 'forwards a signed edit into a local conversation' do
      conversation = Conversation.create!(uri: nil)
      status.update!(conversation_id: conversation.id, visibility: :public)
      context_uri = 'https://cb6e6126.example/contexts/1'
      payload[:context] = context_uri
      payload[:to] = [context_uri]
      activity = signed_activity
      activity['to'] = [context_uri]

      subject.call(status, activity, Oj.load(Oj.dump(payload)))

      expect(ActivityPub::ForwardDistributionWorker).to have_received(:perform_async).with(conversation.id, Oj.dump(activity))
    end

    it 're-evaluates tag follows and keyword subscriptions through the edit fan-out' do
      allow(DistributionWorker).to receive(:perform_async).and_call_original
      subscriber = Fabricate(:user, account: Fabricate(:account, username: 'subuser'), current_sign_in_at: Time.now.utc).account
      tag = Fabricate(:tag, name: 'fresh')
      tag_follow = TagFollow.find_or_create_by!(account: subscriber, tag: tag)
      TagFollowDelivery.create!(tag_follow: tag_follow, list: nil, media_only: false)
      list = Fabricate(:list, account: subscriber, title: 'Watched')
      KeywordSubscribe.create!(
        account: subscriber,
        name: 'edit watch',
        regexp: false,
        match_hashtags: false,
        match_urls: false,
        list_id: list.id,
        exclude_keyword: '',
        keyword: 'freshkeyword'
      )
      redis = FeedManager.instance.__send__(:redis)
      redis.set("subscribed:timeline:#{subscriber.id}", '1')
      redis.set("subscribed:timeline:list:#{list.id}", '1')
      payload[:content] = 'hello freshkeyword'
      payload[:tag] = [{ type: 'Hashtag', name: 'fresh' }]

      subject.call(status, json, json)

      expect(HomeFeed.new(subscriber).get(10).map(&:id)).to include(status.id)
      expect(redis.zscore(FeedManager.instance.key(:list, list.id), status.id)).to_not be_nil
    end
  end

  def json_with(overrides)
    Oj.load(Oj.dump(payload.merge(overrides)))
  end

  def signed_activity
    {
      'id' => 'https://example.com/activities/1',
      'type' => 'Update',
      'actor' => remote_account.uri,
      'signature' => { 'type' => 'RsaSignature2017' },
      'object' => json,
    }
  end

  def remote_follower(username, inbox_url)
    Fabricate(:account, protocol: :activitypub, domain: "#{username}.example", username: username, inbox_url: inbox_url)
  end
end
