require 'rails_helper'

RSpec.describe PostStatusService, type: :service do
  subject { PostStatusService.new }

  it 'creates a new status' do
    account = Fabricate(:account)
    text = "test status update"

    status = subject.call(account, text: text)

    expect(status).to be_persisted
    expect(status.text).to eq text
  end

  it 'creates mentions when no allow-list is given' do
    account = Fabricate(:account)
    alice = Fabricate(:account, username: 'alice')
    bob = Fabricate(:account, username: 'bob')

    status = subject.call(account, text: '@alice hello @bob')

    expect(status).to be_persisted
    expect(status.mentions.map(&:account)).to contain_exactly(alice, bob)
  end

  it 'accepts an explicit mention that is on the allow-list' do
    account = Fabricate(:account)
    alice = Fabricate(:account, username: 'alice')

    status = subject.call(account, text: '@alice hello', allowed_mentions: [alice.id])

    expect(status).to be_persisted
    expect(status.mentions.map(&:account)).to contain_exactly(alice)
  end

  it 'rejects an unexpected mention without saving the status' do
    account = Fabricate(:account)
    alice = Fabricate(:account, username: 'alice')
    bob = Fabricate(:account, username: 'bob')
    allow(DistributionWorker).to receive(:perform_async)

    expect do
      subject.call(account, text: '@alice hello @bob', allowed_mentions: [alice.id])
    end.to raise_error(an_instance_of(PostStatusService::UnexpectedMentionsError).and(having_attributes(accounts: [bob])))

    expect(Status.where(text: '@alice hello @bob')).to be_empty
    expect(Mention.where(account: [alice, bob])).to be_empty
    expect(DistributionWorker).not_to have_received(:perform_async)
  end

  it 'rejects every mention when the allow-list is explicitly empty' do
    account = Fabricate(:account)
    alice = Fabricate(:account, username: 'alice')

    expect do
      subject.call(account, text: '@alice hello', allowed_mentions: [])
    end.to raise_error(PostStatusService::UnexpectedMentionsError)

    expect(Status.where(text: '@alice hello')).to be_empty
    expect(Mention.where(account: alice)).to be_empty
  end

  it 'allows a circle post with an empty allow-list when the text has no mentions' do
    account = Fabricate(:account)
    circle = Fabricate(:circle, account: account)
    member = Fabricate(:account)
    member.follow!(account)
    circle.accounts << member

    status = subject.call(account, text: 'こんにちは', circle: circle, allowed_mentions: [])

    expect(status).to be_persisted
    expect(status.mentions.map(&:account)).to include(member)
  end

  it 'allows a limited reply with an empty allow-list when the text has no mentions' do
    account = Fabricate(:account)
    parent_account = Fabricate(:account)
    parent = Fabricate(:status, account: parent_account, visibility: :limited)
    audience = Fabricate(:account)
    parent.mentions.create!(account: audience, silent: true)

    status = subject.call(account, text: 'hello', thread: parent, visibility: :limited, allowed_mentions: [])

    expect(status).to be_persisted
    expect(status.mentions.map(&:account_id)).to include(audience.id, parent_account.id)
  end

  it 'does not treat circle members as unexpected text mentions' do
    account = Fabricate(:account)
    alice = Fabricate(:account, username: 'circle_alice')
    member = Fabricate(:account)
    member.follow!(account)
    circle = Fabricate(:circle, account: account)
    circle.accounts << member

    status = subject.call(account, text: '@circle_alice hello', circle: circle, allowed_mentions: [alice.id])

    expect(status).to be_persisted
    expect(status.mentions.map(&:account)).to include(alice, member)
  end

  it 'does not persist mentions or notifications while previewing' do
    account = Fabricate(:account)
    alice = Fabricate(:account, username: 'preview_alice')
    status = account.statuses.new(text: '@preview_alice hello', visibility: :public)
    allow(LocalNotificationWorker).to receive(:perform_async)

    expect do
      ProcessMentionsService.new.call(status, nil, save_records: false)
    end.not_to change { [Mention.count, ModerationInteractionEvent.count] }

    expect(status.mentions.map(&:account)).to contain_exactly(alice)
    expect(status.mentions).to all(be_new_record)
    expect(LocalNotificationWorker).not_to have_received(:perform_async)
  end

  it 'accepts duplicate mentions of an allowed account once' do
    account = Fabricate(:account)
    alice = Fabricate(:account, username: 'alice')

    status = subject.call(account, text: '@alice @alice hey @alice', allowed_mentions: [alice.id])

    expect(status).to be_persisted
    expect(status.mentions.map(&:account)).to contain_exactly(alice)
  end

  it 'creates a new response status' do
    in_reply_to_status = Fabricate(:status)
    account = Fabricate(:account)
    text = "test status update"

    status = subject.call(account, text: text, thread: in_reply_to_status)

    expect(status).to be_persisted
    expect(status.text).to eq text
    expect(status.thread).to eq in_reply_to_status
  end

  it 'creates a new status for a given circle' do
    account = Fabricate(:account)
    circle  = Fabricate(:circle, account: account)

    circle_accounts = Fabricate.times(4, :account)

    circle_accounts.each do |target_account|
      target_account.follow!(account)
      circle.accounts << target_account
    end

    text   = 'Circle... hello'
    status = subject.call(account, text: text, circle: circle)

    expect(status).to be_persisted
    expect(status.text).to eq text
    expect(status.visibility).to eq 'limited'
    expect(status.mentions.map(&:account)).to include(*circle_accounts)
  end

  it 'schedules a status' do
    account = Fabricate(:account)
    future  = Time.now.utc + 2.hours

    status = subject.call(account, text: 'Hi future!', scheduled_at: future)

    expect(status).to be_a ScheduledStatus
    expect(status.scheduled_at).to eq future
    expect(status.params['text']).to eq 'Hi future!'
  end

  it 'does not immediately create a status when scheduling a status' do
    account = Fabricate(:account)
    media = Fabricate(:media_attachment, account: account)
    future  = Time.now.utc + 2.hours

    status = subject.call(account, text: 'Hi future!', media_ids: [media.id], scheduled_at: future)

    expect(status).to be_a ScheduledStatus
    expect(status.scheduled_at).to eq future
    expect(status.params['text']).to eq 'Hi future!'
    expect(media.reload.status).to be_nil
    expect(Status.where(text: 'Hi future!').exists?).to be_falsey
  end

  it 'does not persist a scheduled reply or change its counters' do
    account = Fabricate(:account)
    future = Time.now.utc + 2.hours
    previous_status = Fabricate(:status, account: account)

    expect do
      subject.call(account, text: 'Hi future!', scheduled_at: future, thread: previous_status)
    end.not_to change { [account.reload.statuses_count, previous_status.reload.replies_count] }

    expect(Status.where(text: 'Hi future!')).to be_empty
  end

  it 'returns existing status when used twice with idempotency key' do
    account = Fabricate(:account)
    future = Time.now.utc + 2.hours

    status1 = subject.call(account, text: 'test', idempotency: 'meepmeep', scheduled_at: future)
    status2 = subject.call(account, text: 'test', idempotency: 'meepmeep', scheduled_at: future)
    expect(status2.id).to eq status1.id
  end

  it 'creates response to the original status of boost' do
    boosted_status = Fabricate(:status)
    in_reply_to_status = Fabricate(:status, reblog: boosted_status)
    account = Fabricate(:account)
    text = "test status update"

    status = subject.call(account, text: text, thread: in_reply_to_status)

    expect(status).to be_persisted
    expect(status.text).to eq text
    expect(status.thread).to eq boosted_status
  end

  it 'creates a sensitive status' do
    status = create_status_with_options(sensitive: true)

    expect(status).to be_persisted
    expect(status).to be_sensitive
  end

  it 'creates a status with spoiler text' do
    spoiler_text = "spoiler text"

    status = create_status_with_options(spoiler_text: spoiler_text)

    expect(status).to be_persisted
    expect(status.spoiler_text).to eq spoiler_text
  end

  it 'creates a sensitive status when there is a CW but no text' do
    status = subject.call(Fabricate(:account), text: '', spoiler_text: 'foo')

    expect(status).to be_persisted
    expect(status).to be_sensitive
  end

  it 'creates a status with empty default spoiler text' do
    status = create_status_with_options(spoiler_text: nil)

    expect(status).to be_persisted
    expect(status.spoiler_text).to eq ''
  end

  it 'creates a status with the given visibility' do
    status = create_status_with_options(visibility: :private)

    expect(status).to be_persisted
    expect(status.visibility).to eq "private"
  end

  it 'creates a status with limited visibility for silenced users' do
    status = subject.call(Fabricate(:account, silenced: true), text: 'test', visibility: :public)

    expect(status).to be_persisted
    expect(status.visibility).to eq "unlisted"
  end

  it 'creates a status for the given application' do
    application = Fabricate(:application)

    status = create_status_with_options(application: application)

    expect(status).to be_persisted
    expect(status.application).to eq application
  end

  it 'creates a status with a language set' do
    account = Fabricate(:account)
    text = 'This is an English text.'

    status = subject.call(account, text: text)

    expect(status.language).to eq 'en'
  end

  it 'resolves mentions before the status exists and delivers them after commit' do
    mention_service = ProcessMentionsService.new
    allow(ProcessMentionsService).to receive(:new).and_return(mention_service)
    baseline = ApplicationRecord.connection.open_transactions
    account = Fabricate(:account)

    expect(mention_service).to receive(:prepare).ordered.and_wrap_original do |method, status, circle|
      expect(status).not_to be_persisted
      expect(circle).to be_nil
      method.call(status, circle)
    end
    expect(mention_service).to receive(:persist_mentions!).ordered.and_wrap_original do |method, status|
      expect(status).to be_persisted
      expect(ApplicationRecord.connection.open_transactions).to be > baseline
      method.call(status)
    end
    expect(mention_service).to receive(:record_and_deliver!).ordered.and_wrap_original do |method, status, mentions = nil|
      expect(status).to be_persisted
      expect(ApplicationRecord.connection.open_transactions).to eq baseline
      method.call(status, mentions)
    end

    status = subject.call(account, text: 'test status update')

    expect(status).to be_persisted
  end

  [
    'Hello #one #two',
    "Hello\n#one #two",
    "Hello\n\n#one #two",
    "Hello\n\n\n#one",
    '#one #two',
    'Hello #inline text #end',
    "Hello\r\n#one",
    "Hello\r\n\r\n#one",
    "日本語 \t＃タグ #MixedCase  \t",
    "Hello \t\r\n \t#one #two \t",
    "Hello\n\n#one\n#two  ",
  ].each do |text|
    it "preserves authored hashtag spacing on create: #{text.inspect}" do
      status = subject.call(Fabricate(:account), text: text.dup)

      expect(status.text).to eq text
      expect(status.reload.text).to eq text
      expect(status.tags).not_to be_empty
    end

    it "preserves authored hashtag spacing through scheduled publication: #{text.inspect}" do
      account = Fabricate(:account)
      scheduled = subject.call(account, text: text.dup, scheduled_at: 2.hours.from_now)

      expect(scheduled).to be_a(ScheduledStatus)
      expect(scheduled.reload.params['text']).to eq text

      PublishScheduledStatusWorker.new.perform(scheduled.id)

      published = account.statuses.first!
      expect(published.text).to eq text
      expect(published.reload.text).to eq text
      expect(published.tags).not_to be_empty
    end
  end

  [false, true].each do |schedule|
    it "rejects over-limit whitespace with media on #{schedule ? 'schedule' : 'create'} without rewriting it" do
      account = Fabricate(:account)
      media = MediaAttachment.create!(account: account, type: :image, file_file_name: 'test.jpg', file_content_type: 'image/jpeg', file_file_size: 1)
      text = ' ' * (StatusLengthValidator::MAX_CHARS + 1)
      options = { text: text, media_ids: [media.id] }
      options[:scheduled_at] = 2.hours.from_now if schedule

      expect { subject.call(account, options) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(text).to eq(' ' * (StatusLengthValidator::MAX_CHARS + 1))
      expect(account.statuses.reload).to be_empty
      expect(account.scheduled_statuses.reload).to be_empty
      expect(media.reload.status_id).to be_nil
    end

    it "preserves whitespace at the limit with media on #{schedule ? 'scheduled publish' : 'create'}" do
      account = Fabricate(:account)
      media = MediaAttachment.create!(account: account, type: :image, file_file_name: 'test.jpg', file_content_type: 'image/jpeg', file_file_size: 1)
      text = ' ' * StatusLengthValidator::MAX_CHARS
      options = { text: text, media_ids: [media.id] }
      options[:scheduled_at] = 2.hours.from_now if schedule
      result = subject.call(account, options)

      if schedule
        expect(result.reload.params['text']).to eq text
        PublishScheduledStatusWorker.new.perform(result.id)
      end

      expect(account.statuses.first!.reload.text).to eq(' ' * StatusLengthValidator::MAX_CHARS)
      expect(media.reload.status_id).to eq account.statuses.first!.id
    end
  end

  it 'processes hashtags' do
    hashtags_service = double(:process_hashtags_service)
    allow(hashtags_service).to receive(:call)
    allow(ProcessHashtagsService).to receive(:new).and_return(hashtags_service)
    account = Fabricate(:account)

    status = subject.call(account, text: "test status update")

    expect(ProcessHashtagsService).to have_received(:new)
    expect(hashtags_service).to have_received(:call).with(status)
  end

  it 'gets distributed' do
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)

    account = Fabricate(:account)

    status = subject.call(account, text: "test status update")

    expect(DistributionWorker).to have_received(:perform_async).with(status.id)
    expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
  end

  it 'enqueues link crawling instead of running it inline' do
    allow(LinkCrawlWorker).to receive(:perform_async)
    expect(LinkCrawlWorker).not_to receive(:new)
    expect(StatusPublishPreparationWorker).not_to receive(:perform_async)
    account = Fabricate(:account)

    status = subject.call(account, text: 'test status update')

    expect(LinkCrawlWorker).to have_received(:perform_async).with(status.id)
  end

  it 'attaches the given media to the created status' do
    account = Fabricate(:account)
    media = Fabricate(:media_attachment, account: account)

    status = subject.call(
      account,
      text: "test status update",
      media_ids: [media.id],
    )

    expect(media.reload.status).to eq status
  end

  it 'refuses media from another account instead of publishing without it' do
    account = Fabricate(:account)
    media = Fabricate(:media_attachment, account: Fabricate(:account))

    expect do
      subject.call(
        account,
        text: 'test status update',
        media_ids: [media.id],
      )
    end.to raise_error(
      Mastodon::ValidationError,
      I18n.t('media_attachments.validations.missing'),
    )

    expect(Status.where(account: account, text: 'test status update')).to be_empty
    expect(media.reload.status_id).to be_nil
  end

  it 'refuses a post when any requested attachment is still on another status' do
    account = Fabricate(:account)
    ready = Fabricate(:media_attachment, account: account, description: 'ready alt')
    held_status = Fabricate(:status, account: account, text: 'still holding media')
    held = Fabricate(:media_attachment, account: account, status: held_status, description: 'held alt')

    expect do
      subject.call(
        account,
        text: 'redraft too early',
        media_ids: [ready.id, held.id],
      )
    end.to raise_error(
      Mastodon::ValidationError,
      I18n.t('media_attachments.validations.missing'),
    )

    expect(Status.where(account: account, text: 'redraft too early')).to be_empty
    expect(ready.reload.status_id).to be_nil
    expect(held.reload.status_id).to eq held_status.id
    expect(held.description).to eq 'held alt'
  end

  it 'refuses a missing or destroyed media id' do
    account = Fabricate(:account)
    destroyed = Fabricate(:media_attachment, account: account)
    destroyed_id = destroyed.id
    destroyed.destroy!

    expect do
      subject.call(account, text: 'missing media', media_ids: [0])
    end.to raise_error(Mastodon::ValidationError, I18n.t('media_attachments.validations.missing'))

    expect do
      subject.call(account, text: 'destroyed media', media_ids: [destroyed_id])
    end.to raise_error(Mastodon::ValidationError, I18n.t('media_attachments.validations.missing'))

    expect(Status.where(account: account, text: ['missing media', 'destroyed media'])).to be_empty
  end

  it 'reuses a detached attachment with its updated description' do
    account = Fabricate(:account)
    media = Fabricate(:media_attachment, account: account, description: 'fresh alt')

    status = subject.call(account, text: 'posted again', media_ids: [media.id])

    expect(status.ordered_media_attachment_ids).to eq [media.id]
    expect(media.reload.status_id).to eq status.id
    expect(media.description).to eq 'fresh alt'
  end

  it 'does not allow attaching more than 4 files' do
    account = Fabricate(:account)

    expect do
      subject.call(
        account,
        text: "test status update",
        media_ids: [
          Fabricate(:media_attachment, account: account),
          Fabricate(:media_attachment, account: account),
          Fabricate(:media_attachment, account: account),
          Fabricate(:media_attachment, account: account),
          Fabricate(:media_attachment, account: account),
        ].map(&:id),
      )
    end.to raise_error(
      Mastodon::ValidationError,
      I18n.t('media_attachments.validations.too_many'),
    )
  end

  it 'does not allow attaching both videos and images' do
    account = Fabricate(:account)
    video   = Fabricate(:media_attachment, type: :video, account: account)
    image   = Fabricate(:media_attachment, type: :image, account: account)

    video.update(type: :video)

    expect do
      subject.call(
        account,
        text: "test status update",
        media_ids: [
          video,
          image,
        ].map(&:id),
      )
    end.to raise_error(
      Mastodon::ValidationError,
      I18n.t('media_attachments.validations.images_and_video'),
    )
  end

  it 'does not allow more than one video or audio attachment' do
    account = Fabricate(:account)
    first_video = Fabricate(:media_attachment, type: :video, account: account)
    second_video = Fabricate(:media_attachment, type: :video, account: account)
    first_video.update(type: :video)
    second_video.update(type: :video)
    audio = MediaAttachment.new(account: account, type: :audio, file_file_name: 'talk.mp3', file_content_type: 'audio/mpeg', file_file_size: 1)
    audio.save!(validate: false)
    image = Fabricate(:media_attachment, type: :image, account: account)

    expect do
      subject.call(account, text: 'two videos', media_ids: [first_video.id, second_video.id])
    end.to raise_error(Mastodon::ValidationError, I18n.t('media_attachments.validations.images_and_video'))

    expect do
      subject.call(account, text: 'audio and image', media_ids: [audio.id, image.id])
    end.to raise_error(Mastodon::ValidationError, I18n.t('media_attachments.validations.images_and_video'))

    expect(first_video.reload.status_id).to be_nil
    expect(second_video.reload.status_id).to be_nil
    expect(audio.reload.status_id).to be_nil
  end

  it 'returns existing status when used twice with idempotency key' do
    account = Fabricate(:account)
    status1 = subject.call(account, text: 'test', idempotency: 'meepmeep')
    status2 = subject.call(account, text: 'test', idempotency: 'meepmeep')
    expect(status2.id).to eq status1.id
  end

  context 'when mention processing is part of status creation' do
    let(:account) { Fabricate(:account) }
    let(:baseline_transactions) { ApplicationRecord.connection.open_transactions }

    before { baseline_transactions }

    it 'does not leave a status when mention resolution raises' do
      Fabricate(:account, username: 'alice')
      allow(DistributionWorker).to receive(:perform_async)
      allow(ActivityPub::DistributionWorker).to receive(:perform_async)
      # Redis lock failure while resolving a remote account is not one of
      # the webfinger/HTTP errors mention processing ignores.
      allow_any_instance_of(ResolveAccountService).to receive(:call).and_raise(Mastodon::RaceConditionError)

      expect do
        subject.call(account, text: 'Hello @ghost@remote.example', visibility: :limited)
      end.to raise_error(Mastodon::RaceConditionError)
        .and(not_change { Status.count })
        .and(not_change { Mention.count })
        .and(not_change { StatusCapabilityToken.count })

      expect(DistributionWorker).not_to have_received(:perform_async)
      expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
    end

    it 'rolls the status back when mention persistence fails' do
      alice = Fabricate(:account, username: 'alice')
      mention_service = ProcessMentionsService.new
      allow(ProcessMentionsService).to receive(:new).and_return(mention_service)
      allow(mention_service).to receive(:prepare).and_wrap_original do |method, status, circle|
        explicit = method.call(status, circle)
        status.mentions.build(account: explicit.first.account)
        explicit
      end
      expect(mention_service).not_to receive(:record_and_deliver!)
      allow(DistributionWorker).to receive(:perform_async)

      expect do
        subject.call(account, text: '@alice hello', visibility: :limited)
      end.to raise_error(ActiveRecord::RecordInvalid)
        .and(not_change { Status.count })
        .and(not_change { Mention.count })
        .and(not_change { StatusCapabilityToken.count })

      expect(Mention.where(account: alice)).to be_empty
      expect(DistributionWorker).not_to have_received(:perform_async)
    end

    it 'saves a canonical local mention and enqueues notification after commit' do
      alice = Fabricate(:account, username: 'alice')
      notified_mention_id = nil
      allow(LocalNotificationWorker).to receive(:perform_async).and_wrap_original do |method, receiver_id, mention_id, class_name, type|
        expect(ApplicationRecord.connection.open_transactions).to eq baseline_transactions
        expect(Mention.exists?(mention_id)).to be true
        notified_mention_id = mention_id
        method.call(receiver_id, mention_id, class_name, type)
      end

      status = subject.call(account, text: 'Hello @alice @alice')

      mention = status.mentions.find_by!(account: alice)
      expect(status.text).to eq 'Hello @alice @alice'
      expect(status.mentions.map(&:account)).to contain_exactly(alice)
      expect(mention).not_to be_silent
      expect(notified_mention_id).to eq mention.id
      expect(LocalNotificationWorker).to have_received(:perform_async).with(alice.id, mention.id, 'Mention', 'mention').once
    end

    it 'saves a canonical remote mention and enqueues ActivityPub delivery after commit' do
      remote = Fabricate(:account, username: 'remote_user', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox')
      stub_request(:post, remote.inbox_url)
      allow(ActivityPub::DeliveryWorker).to receive(:perform_async).and_wrap_original do |method, *args|
        expect(ApplicationRecord.connection.open_transactions).to eq baseline_transactions
        method.call(*args)
      end

      status = subject.call(account, text: 'Hello @remote_user@example.com')

      expect(status.text).to eq 'Hello @remote_user@example.com'
      expect(status.mentions.map(&:account)).to contain_exactly(remote)
      expect(a_request(:post, remote.inbox_url)).to have_been_made.once
    end

    it 'leaves an unresolvable mention in the text and stores no mention row' do
      stub_request(:get, 'https://missing.example/.well-known/webfinger?resource=acct:ghost@missing.example').to_return(status: 404)
      stub_request(:get, 'https://missing.example/.well-known/host-meta').to_return(status: 404)

      status = subject.call(account, text: 'Hello @ghost@missing.example')

      expect(status).to be_persisted
      expect(status.text).to eq 'Hello @ghost@missing.example'
      expect(status.mentions).to be_empty
    end

    it 'does not mention a suspended account' do
      suspended = Fabricate(:account, username: 'suspended_user', suspended: true)
      allow(LocalNotificationWorker).to receive(:perform_async)

      status = subject.call(account, text: 'Hello @suspended_user')

      expect(status.text).to eq 'Hello @suspended_user'
      expect(status.mentions).to be_empty
      expect(LocalNotificationWorker).not_to have_received(:perform_async)
    end

    it 'does not mention an undeliverable remote account' do
      remote = Fabricate(:account, username: 'old_user', domain: 'ostatus.example', protocol: :ostatus, inbox_url: 'http://ostatus.example/inbox')
      allow_any_instance_of(ResolveAccountService).to receive(:call).and_return(remote)
      allow(ActivityPub::DeliveryWorker).to receive(:perform_async)

      status = subject.call(account, text: 'Hello @old_user@ostatus.example')

      expect(status.text).to eq 'Hello @old_user@ostatus.example'
      expect(remote.mentions).to be_empty
      expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
    end

    it 'creates a reply and its mention together' do
      alice = Fabricate(:account, username: 'alice')
      parent = Fabricate(:status, account: alice, text: 'original')
      allow(LocalNotificationWorker).to receive(:perform_async)

      status = nil
      expect do
        status = subject.call(account, text: '@alice thanks', thread: parent)
      end.to change(ModerationInteractionEvent, :count).by(1)

      mention = status.mentions.find_by!(account: alice)
      expect(status.thread).to eq parent
      expect(status.in_reply_to_account_id).to eq alice.id
      expect(mention).not_to be_silent
      expect(status.text).to eq '@alice thanks'
      event = ModerationInteractionEvent.order(:id).last
      expect(event.event_type).to eq 'reply'
      expect(event.status_id).to eq status.id
      expect(LocalNotificationWorker).to have_received(:perform_async).with(alice.id, mention.id, 'Mention', 'mention')
    end

    it 'keeps explicit mentions, thread audience, and the replied-to account on a limited reply' do
      parent_account = Fabricate(:account, username: 'parent')
      audience = Fabricate(:account, username: 'audience')
      explicit = Fabricate(:account, username: 'explicit')
      parent = Fabricate(:status, account: parent_account, visibility: :limited, text: 'limited thread')
      parent.mentions.create!(account: audience, silent: true)
      allow(LocalNotificationWorker).to receive(:perform_async)

      status = subject.call(account, text: '@explicit hello', thread: parent, visibility: :limited)

      expect(status.visibility).to eq 'limited'
      expect(status.capability_tokens).to exist
      expect(status.mentions.find_by!(account: explicit)).not_to be_silent
      expect(status.mentions.find_by!(account: audience)).to be_silent
      expect(status.mentions.find_by!(account: parent_account)).to be_silent
      expect(LocalNotificationWorker).to have_received(:perform_async).with(explicit.id, status.mentions.find_by!(account: explicit).id, 'Mention', 'mention')
      expect(LocalNotificationWorker).not_to have_received(:perform_async).with(audience.id, anything, 'Mention', 'mention')
      expect(LocalNotificationWorker).not_to have_received(:perform_async).with(parent_account.id, anything, 'Mention', 'mention')
    end

    it 'keeps circle members as silent mentions' do
      member = Fabricate(:account)
      member.follow!(account)
      circle = Fabricate(:circle, account: account)
      circle.accounts << member
      allow(LocalNotificationWorker).to receive(:perform_async)

      status = subject.call(account, text: 'circle hello', circle: circle)

      expect(status.visibility).to eq 'limited'
      expect(status.capability_tokens).to exist
      expect(status.mentions.find_by!(account: member)).to be_silent
      expect(LocalNotificationWorker).not_to have_received(:perform_async)
    end

    it 'does not save a status when an allow-list rejects a mention' do
      alice = Fabricate(:account, username: 'alice')
      bob = Fabricate(:account, username: 'bob')
      allow(DistributionWorker).to receive(:perform_async)

      expect do
        subject.call(account, text: '@alice hello @bob', allowed_mentions: [alice.id], visibility: :limited)
      end.to raise_error(PostStatusService::UnexpectedMentionsError)
        .and(not_change { Status.count })
        .and(not_change { Mention.count })
        .and(not_change { StatusCapabilityToken.count })

      expect(Mention.where(account: [alice, bob])).to be_empty
      expect(DistributionWorker).not_to have_received(:perform_async)
    end

    it 'does not process mentions for a personal status' do
      alice = Fabricate(:account, username: 'alice')
      personal_account = Fabricate(:user).account
      allow(LocalNotificationWorker).to receive(:perform_async)
      allow(ActivityPub::DistributionWorker).to receive(:perform_async)

      status = subject.call(personal_account, text: 'Hello @alice', visibility: :personal)

      expect(status.visibility).to eq 'personal'
      expect(status.text).to eq 'Hello @alice'
      expect(status.mentions).to be_empty
      expect(status.capability_tokens).not_to exist
      expect(LocalNotificationWorker).not_to have_received(:perform_async)
      expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
    end

    it 'reblogs a local group mention after the status transaction commits' do
      group = Fabricate(:user, account: Fabricate(:account, username: 'localsquad', actor_type: 'Group')).account
      reblog_service = instance_double(ReblogService, call: nil)
      allow(ReblogService).to receive(:new).and_return(reblog_service)
      allow(reblog_service).to receive(:call) do |reblogger, status, options|
        expect(ApplicationRecord.connection.open_transactions).to eq baseline_transactions
        expect(status).to be_persisted
        expect(reblogger).to eq group
        expect(options).to have_key(:visibility)
      end

      status = subject.call(account, text: '@localsquad hello')

      expect(status.mentions.find_by!(account: group)).not_to be_silent
      expect(reblog_service).to have_received(:call)
    end
  end

  context 'when publishing is gated on redirect resolution' do
    let(:account) { Fabricate(:account) }

    before do
      allow(DistributionWorker).to receive(:perform_async)
      allow(PriorityDistributionWorker).to receive(:perform_async)
      allow(ActivityPub::DistributionWorker).to receive(:perform_async)
      allow(LinkCrawlWorker).to receive(:perform_async)
      allow(StatusPublishPreparationWorker).to receive(:perform_async)
      allow(LocalNotificationWorker).to receive(:perform_async)
      allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    end

    it 'publishes a status with no URL without an external request' do
      expect(Request).not_to receive(:new)

      status = subject.call(account, text: 'test status update')

      expect(status).to be_persisted
      expect(StatusPublishPreparationWorker).not_to have_received(:perform_async)
      expect(DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(LinkCrawlWorker).to have_received(:perform_async).with(status.id)
      expect(StatusPublishPreparationService.new.marked?(status)).to be false
    end

    it 'publishes an ordinary URL without waiting for a preview card' do
      # Unknown hosts are still looked up as possible fediverse nodes.
      # That lookup is not link crawling, and is not part of this barrier.
      allow(Node).to receive(:resolve_domain).and_return(nil)
      expect(Request).not_to receive(:new)

      status = subject.call(account, text: 'read https://example.com/article')

      expect(StatusPublishPreparationWorker).not_to have_received(:perform_async)
      expect(DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(LinkCrawlWorker).to have_received(:perform_async).with(status.id)
      expect(status.preview_cards).to be_empty
    end

    it 'publishes immediately when the redirect target is already known' do
      short_url = 'https://bit.ly/known'
      final_url = 'https://example.com/known-target'
      RedirectLink.create!(url: short_url, redirected_url: final_url)
      expect(Request).not_to receive(:new)

      status = subject.call(account, text: "see #{short_url}")

      expect(StatusPublishPreparationWorker).not_to have_received(:perform_async)
      expect(DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(Formatter.instance.format(status, rest: true)).to include(%(href="#{final_url}"))
    end

    it 'does not publish while a redirect URL is unresolved' do
      alice = Fabricate(:account, username: 'alice')
      remote = Fabricate(:account, username: 'remote_user', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox')
      group = Fabricate(:user, account: Fabricate(:account, username: 'localsquad', actor_type: 'Group')).account
      reblog_service = instance_double(ReblogService, call: nil)
      allow(ReblogService).to receive(:new).and_return(reblog_service)
      expect(Request).not_to receive(:new)

      status = subject.call(account, text: "https://bit.ly/pending @alice @remote_user@example.com @localsquad")

      expect(status).to be_persisted
      expect(status.mentions.find_by(account: alice)).to be_present
      expect(StatusPublishPreparationWorker).to have_received(:perform_async).with(status.id)
      expect(StatusPublishPreparationService.new.marked?(status)).to be true
      expect(DistributionWorker).not_to have_received(:perform_async)
      expect(PriorityDistributionWorker).not_to have_received(:perform_async)
      expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
      expect(LocalNotificationWorker).not_to have_received(:perform_async)
      expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)
      expect(reblog_service).not_to have_received(:call)
      expect(LinkCrawlWorker).not_to have_received(:perform_async)
    end

    it 'keeps waiting when only one of two redirect URLs is known' do
      RedirectLink.create!(url: 'https://bit.ly/ready', redirected_url: 'https://example.com/ready')

      status = subject.call(account, text: 'https://bit.ly/ready https://t.co/waiting')

      expect(StatusPublishPreparationWorker).to have_received(:perform_async).with(status.id)
      expect(DistributionWorker).not_to have_received(:perform_async)
      expect(StatusPublishPreparationService.new.unresolved_redirect_urls(status)).to eq ['https://t.co/waiting']
    end

    it 'publishes when every redirect URL is already known' do
      RedirectLink.create!(url: 'https://bit.ly/ready', redirected_url: 'https://example.com/ready')
      RedirectLink.create!(url: 'https://t.co/ready', redirected_url: 'https://example.org/ready')

      status = subject.call(account, text: 'https://bit.ly/ready https://t.co/ready')

      expect(StatusPublishPreparationWorker).not_to have_received(:perform_async)
      expect(DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
    end

    it 'starts publishing before poll expiration scheduling can fail' do
      allow(PollExpirationNotifyWorker).to receive(:perform_at).and_raise(Redis::CannotConnectError, 'poll down')

      expect do
        subject.call(account, text: 'vote', poll: { options: %w(Yes No), expires_in: 1.day.to_i })
      end.to raise_error(Redis::CannotConnectError)

      status = account.statuses.find_by!(text: 'vote')
      expect(DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(PublishStatusService.new.published?(status)).to be true
    end

    it 'enqueues redirect preparation before poll expiration scheduling can fail' do
      allow(PollExpirationNotifyWorker).to receive(:perform_at).and_raise(Redis::CannotConnectError, 'poll down')

      expect do
        subject.call(account, text: 'https://bit.ly/vote', poll: { options: %w(Yes No), expires_in: 1.day.to_i })
      end.to raise_error(Redis::CannotConnectError)

      status = account.statuses.find_by!(text: 'https://bit.ly/vote')
      expect(StatusPublishPreparationWorker).to have_received(:perform_async).with(status.id)
      expect(DistributionWorker).not_to have_received(:perform_async)
      expect(StatusPublishPreparationService.new.marked?(status)).to be true
    end

    it 'logs and does not publish when preparation cannot be enqueued' do
      allow(StatusPublishPreparationWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError, 'redis down')
      allow(Rails.logger).to receive(:error)

      status = nil
      expect do
        status = subject.call(account, text: 'https://bit.ly/enqueue-failed')
      end.not_to raise_error

      expect(status).to be_persisted
      expect(DistributionWorker).not_to have_received(:perform_async)
      expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
      expect(StatusPublishPreparationService.new.marked?(status)).to be true
      expect(Rails.logger).to have_received(:error).with(/failed to enqueue status=#{status.id}/)
    end
  end

  def create_status_with_options(**options)
    subject.call(Fabricate(:account), **options.merge(text: 'test'))
  end
end
