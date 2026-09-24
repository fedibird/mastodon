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
    media = Fabricate(:media_attachment)
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

  it 'processes mentions' do
    mention_service = double(:process_mentions_service)
    allow(mention_service).to receive(:call)
    allow(ProcessMentionsService).to receive(:new).and_return(mention_service)
    account = Fabricate(:account)

    status = subject.call(account, text: "test status update")

    expect(ProcessMentionsService).to have_received(:new)
    expect(mention_service).to have_received(:call).with(status, nil)
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

  it 'crawls links' do
    worker = instance_double(LinkCrawlWorker, perform: true)
    allow(LinkCrawlWorker).to receive(:new).and_return(worker)
    account = Fabricate(:account)

    status = subject.call(account, text: "test status update")

    expect(worker).to have_received(:perform).with(status.id)
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

  it 'does not attach media from another account to the created status' do
    account = Fabricate(:account)
    media = Fabricate(:media_attachment, account: Fabricate(:account))

    status = subject.call(
      account,
      text: "test status update",
      media_ids: [media.id],
    )

    expect(media.reload.status).to eq nil
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

  it 'returns existing status when used twice with idempotency key' do
    account = Fabricate(:account)
    status1 = subject.call(account, text: 'test', idempotency: 'meepmeep')
    status2 = subject.call(account, text: 'test', idempotency: 'meepmeep')
    expect(status2.id).to eq status1.id
  end

  def create_status_with_options(**options)
    subject.call(Fabricate(:account), **options.merge(text: 'test'))
  end
end
