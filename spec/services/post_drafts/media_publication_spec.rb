# frozen_string_literal: true

require 'rails_helper'

describe 'draft media publication guard' do
  let(:user) { Fabricate(:user) }
  let(:media) { Fabricate(:media_attachment, account: user.account, description: 'held') }

  def retain!
    PostDrafts::Store.new(user.account).create(
      client_uuid: '88888888-8888-4888-8888-888888888888',
      payload: {
        'schema_version' => 1,
        'input' => { 'text' => 'draft', 'privacy' => 'personal', 'media' => [{ 'id' => media.id.to_s }] },
      }
    )
  end

  it 'refuses a normal post and a scheduled post while the draft holds the file' do
    retain!
    free = Fabricate(:media_attachment, account: user.account)

    expect do
      PostStatusService.new.call(user.account, text: 'now', media_ids: [media.id])
    end.to raise_error(Mastodon::ValidationError, I18n.t('media_attachments.validations.retained_by_draft'))

    expect do
      PostStatusService.new.call(user.account, text: 'later', media_ids: [media.id], scheduled_at: 10.minutes.from_now)
    end.to raise_error(Mastodon::ValidationError, I18n.t('media_attachments.validations.retained_by_draft'))

    posted = PostStatusService.new.call(user.account, text: 'free', media_ids: [free.id])

    expect(posted).to be_persisted
    expect(free.reload.status_id).to eq posted.id
    expect(media.reload.status_id).to be_nil
    expect(media.scheduled_status_id).to be_nil
    expect(media.description).to eq 'held'
    expect(PostDraftMediaAttachment.exists?(media_attachment_id: media.id)).to be true
    expect(Status.where(text: %w(now later))).to be_empty
    expect(ScheduledStatus.where(account: user.account)).to be_empty
  end

  it 'refuses an edit that would take the drafted file' do
    retain!
    status = Fabricate(:status, account: user.account, text: 'kept')

    expect do
      UpdateStatusService.new.call(status, user.account.id, text: 'changed', media_ids: [media.id])
    end.to raise_error(Mastodon::ValidationError, I18n.t('media_attachments.validations.retained_by_draft'))

    expect(status.reload.text).to eq 'kept'
    expect(media.reload.status_id).to be_nil
    expect(PostDraftMediaAttachment.exists?(media_attachment_id: media.id)).to be true
  end
end
