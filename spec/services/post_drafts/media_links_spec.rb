# frozen_string_literal: true

require 'rails_helper'

describe PostDrafts::MediaLinks do
  let(:user) { Fabricate(:user) }
  let(:store) { PostDrafts::Store.new(user.account) }
  let(:uuid) { '11111111-1111-4111-8111-111111111111' }
  let(:other_uuid) { '22222222-2222-4222-8222-222222222222' }

  def item(id, order: 0, description: 'snapshot alt', focus: { 'x' => 0, 'y' => 0 })
    { 'id' => id.to_s, 'order' => order, 'description' => description, 'focus' => focus }
  end

  def field(row, key)
    row[key.to_sym] || row[key.to_s]
  end

  def payload(text, media, extra = {})
    {
      'schema_version' => 1,
      'media_incomplete' => extra.delete('media_incomplete') == true,
      'input' => { 'text' => text, 'privacy' => 'personal', 'media' => media }.merge(extra),
    }
  end

  def finished(account, description: "kept\nalt")
    media = Fabricate(:media_attachment, account: account, description: description)
    media.update!(focus: '0.2,-0.4', thumbnail_file_name: nil)
    media.update_columns(thumbnail_file_name: 'custom-thumb.jpg')
    media
  end

  it 'links finished images in order without copying alt, focus, or thumbnail' do
    first = finished(user.account)
    second = finished(user.account, description: 'second')
    created = store.create(client_uuid: uuid, payload: payload('hello', [
      item(second.id, order: 1, description: 'second'),
      item(first.id, order: 0, description: "other\nalt", focus: { 'x' => -0.25, 'y' => 0.5 }),
    ]))
    view = PostDrafts::Presenter.new(user).one(created.draft)
    restored = view[:media].first

    expect(created.status).to eq :created
    expect(created.draft.post_draft_media_attachments.order(:position).pluck(:media_attachment_id)).to eq [first.id, second.id]
    expect(first.reload.description).to eq "kept\nalt"
    expect(first.focus).to eq '0.2,-0.4'
    expect(first.thumbnail_file_name).to eq 'custom-thumb.jpg'
    expect(first.status_id).to be_nil
    expect(created.draft.payload.dig('input', 'media', 0, 'description')).to eq "other\nalt"
    expect(field(restored, :description)).to eq "other\nalt"
    expect(field(field(restored, :meta), :focus)['x'] || field(field(restored, :meta), :focus)[:x]).to eq(-0.25)
    expect(field(view[:media].last, :description)).to eq 'second'
    expect(field(restored, :preview_url)).to be_present
    expect(Status.count).to eq 0
    expect(ScheduledStatus.count).to eq 0
  end

  it 'does not duplicate links when the same payload is posted again' do
    media = finished(user.account)
    store.create(client_uuid: uuid, payload: payload('hello', [item(media.id)]))
    replay = store.create(client_uuid: uuid, payload: payload('hello', [item(media.id)]))

    expect(replay.status).to eq :existing
    expect(PostDraftMediaAttachment.where(media_attachment_id: media.id).count).to eq 1
  end

  it 'replaces the order in one revision and leaves the previous links on a stale write' do
    first = finished(user.account)
    second = finished(user.account)
    created = store.create(client_uuid: uuid, payload: payload('hello', [item(first.id, order: 0), item(second.id, order: 1)]))
    stale = store.update(created.draft.id, expected_revision: 0, payload: payload('stale', [item(second.id)]))
    updated = store.update(created.draft.id, expected_revision: 1, payload: payload('next', [item(second.id, order: 0), item(first.id, order: 1)]))

    expect(stale.status).to eq :conflict
    expect(PostDrafts::Presenter.new(user).one(created.draft.reload).dig(:media, 0).then { |row| field(row, :description) }).to eq 'snapshot alt'
    expect(updated.status).to eq :updated
    expect(updated.draft.post_draft_media_attachments.order(:position).pluck(:media_attachment_id)).to eq [second.id, first.id]
    expect(first.reload.description).to eq "kept\nalt"
    expect(PostDraftMediaAttachment.where(media_attachment_id: first.id).count).to eq 1
  end

  it 'clears links when the media list becomes empty and keeps the file' do
    media = finished(user.account)
    created = store.create(client_uuid: uuid, payload: payload('hello', [item(media.id)]))
    updated = store.update(created.draft.id, expected_revision: 1, payload: payload('next', []))

    expect(updated.status).to eq :updated
    expect(PostDraftMediaAttachment.where(post_draft_id: created.draft.id)).to be_empty
    expect(media.reload).to be_persisted
    expect(media.description).to eq "kept\nalt"
  end

  it 'rejects the whole save when any attachment is unusable' do
    own = finished(user.account, description: 'untouched')
    other = finished(Fabricate(:account))
    posted = finished(user.account)
    posted.update_columns(status_id: Fabricate(:status, account: user.account).id)
    scheduled = finished(user.account)
    scheduled.update_columns(scheduled_status_id: Fabricate(:scheduled_status, account: user.account).id)
    queued = finished(user.account)
    queued.update_columns(processing: MediaAttachment.processings[:queued])
    failed = finished(user.account)
    failed.update_columns(processing: MediaAttachment.processings[:failed])
    remote = finished(user.account)
    remote.update_columns(remote_url: 'https://example.test/file.jpg')
    video = Fabricate(:media_attachment, account: user.account, type: :video)
    video.update!(type: :video)

    cases = {
      [item('9000000000001')] => 'media_missing',
      [item(other.id)] => 'media_forbidden',
      [item(posted.id)] => 'media_in_use',
      [item(scheduled.id)] => 'media_in_use',
      [item(queued.id)] => 'media_not_ready',
      [item(failed.id)] => 'media_not_ready',
      [item(remote.id)] => 'media_remote',
      [item(own.id), item(video.id, order: 1)] => 'media_mixed',
      [item(own.id)] => 'media_with_poll',
    }

    cases.each do |media, code|
      body = payload('nope', media)
      body['input']['poll'] = { 'options' => %w(a b), 'expires_in' => 3600, 'multiple' => false } if code == 'media_with_poll'
      result = store.create(client_uuid: other_uuid, payload: body)

      expect(result.status).to eq(:invalid), code
      expect(result.error.errors.first['code']).to eq code
    end

    expect(PostDraft.where(account_id: user.account_id)).to be_empty
    expect(own.reload.description).to eq 'untouched'
    expect(PostDraftMediaAttachment.count).to eq 0
  end

  it 'refuses to share one file between two drafts' do
    media = finished(user.account, description: 'shared-no')
    first = store.create(client_uuid: uuid, payload: payload('one', [item(media.id)]))
    second = store.create(client_uuid: other_uuid, payload: payload('two', [item(media.id)]))

    expect(first.status).to eq :created
    expect(second.status).to eq :invalid
    expect(second.error.errors.first['code']).to eq 'media_in_use'
    expect(PostDraft.where(account_id: user.account_id).pluck(:client_uuid)).to eq [uuid]
    expect(media.reload.description).to eq 'shared-no'
  end

  it 'keeps the other draft when one draft is deleted' do
    first_media = finished(user.account)
    second_media = finished(user.account)
    first = store.create(client_uuid: uuid, payload: payload('one', [item(first_media.id)]))
    second = store.create(client_uuid: other_uuid, payload: payload('two', [item(second_media.id)]))

    expect(store.destroy(first.draft.id, expected_revision: 1).status).to eq :deleted
    expect(MediaAttachment.exists?(first_media.id)).to be true
    expect(PostDraftMediaAttachment.where(media_attachment_id: second_media.id).pluck(:post_draft_id)).to eq [second.draft.id]
    expect(second.draft.reload.payload.dig('input', 'text')).to eq 'two'
  end

  it 'saves one video and one audio, and reports a partial restore while an upload is unfinished' do
    video = Fabricate(:media_attachment, account: user.account, type: :video)
    video.update!(type: :video)
    audio = Fabricate(:media_attachment, account: user.account, file: attachment_fixture('boop.mp3'))
    video_draft = store.create(client_uuid: uuid, payload: payload('clip', [item(video.id, description: 'clip')]))
    audio_draft = store.create(client_uuid: other_uuid, payload: payload('sound', [item(audio.id, description: 'sound')], 'media_incomplete' => true))

    expect(video_draft.status).to eq :created
    expect(audio.type).to eq 'audio'
    expect(audio_draft.status).to eq :created
    video_view = PostDrafts::Presenter.new(user).one(video_draft.draft)
    audio_view = PostDrafts::Presenter.new(user).one(audio_draft.draft)
    expect(video_view[:media].map { |row| row[:type] || row['type'] }).to eq ['video']
    expect(audio_view[:media_restore]).to eq 'partial'
    expect(audio_view[:media_retained]).to be true
    expect(audio_view[:media].map { |row| row[:type] || row['type'] }).to eq ['audio']
  end

  it 'locks the attachment rows once for several files' do
    media = Array.new(4) { finished(user.account) }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, event|
      queries << event[:sql] if event[:sql].present?
    end
    result = store.create(client_uuid: uuid, payload: payload('four', media.each_with_index.map { |item, index| item(item.id, order: index) }))
    ActiveSupport::Notifications.unsubscribe(subscriber)

    selects = queries.count { |sql| sql.match?(/SELECT .*FROM "media_attachments"/) }
    expect(result.status).to eq :created
    expect(selects).to eq 1
    expect(PostDraftMediaAttachment.where(post_draft_id: result.draft.id).count).to eq 4
  end

  it 'keeps the file when the association is destroyed and releases it when the owning account is destroyed' do
    media = finished(user.account)
    created = store.create(client_uuid: uuid, payload: payload('hello', [item(media.id)]))

    expect { user.account.media_attachments.destroy(media) }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(MediaAttachment.exists?(media.id)).to be true
    expect(PostDraftMediaAttachment.exists?(media_attachment_id: media.id)).to be true

    media.destroyed_by_association = Account.reflect_on_association(:media_attachments)
    media.destroy!

    expect(MediaAttachment.exists?(media.id)).to be false
    expect(PostDraftMediaAttachment.where(post_draft_id: created.draft.id)).to be_empty
    expect(PostDraft.exists?(created.draft.id)).to be true
  end

  it 'reports a partial restore when the stored file is gone or processing is no longer complete' do
    missing = finished(user.account, description: 'row alt')
    failed = finished(user.account)
    missing_draft = store.create(client_uuid: uuid, payload: payload('gone', [item(missing.id, description: "draft\nalt")]))
    failed_draft = store.create(client_uuid: other_uuid, payload: payload('failed', [item(failed.id, description: 'draft alt')]))
    missing.update_columns(file_file_name: nil)
    failed.update_columns(processing: MediaAttachment.processings[:failed])
    missing_view = PostDrafts::Presenter.new(user).one(missing_draft.draft)
    failed_view = PostDrafts::Presenter.new(user).one(failed_draft.draft)

    expect(missing_view[:media_retained]).to be true
    expect(missing_view[:media_restore]).to eq 'partial'
    expect(missing_view[:media]).to eq []
    expect(missing_draft.draft.payload.dig('input', 'media', 0, 'description')).to eq "draft\nalt"
    expect(failed_view[:media_restore]).to eq 'partial'
    expect(failed_view[:media]).to eq []
    expect(failed.reload.description).to eq "kept\nalt"
  end

  it 'indexes each attachment once and refuses deleting a referenced file at the database' do
    indexes = ActiveRecord::Base.connection.indexes(:post_draft_media_attachments)
    media_index = indexes.find { |index| index.name == 'index_post_draft_media_on_media_attachment_id' }
    position_index = indexes.find { |index| index.name == 'index_post_draft_media_on_draft_and_position' }
    keys = ActiveRecord::Base.connection.foreign_keys(:post_draft_media_attachments)
    media = finished(user.account)
    store.create(client_uuid: uuid, payload: payload('hello', [item(media.id)]))

    expect(media_index.unique).to be true
    expect(media_index.columns).to eq ['media_attachment_id']
    expect(position_index.unique).to be true
    expect(position_index.columns).to eq %w(post_draft_id position)
    expect(keys.map { |key| [key.to_table, key.on_delete] }).to include(['media_attachments', :restrict], ['post_drafts', :cascade])
    expect do
      ApplicationRecord.transaction(requires_new: true) do
        MediaAttachment.where(id: media.id).delete_all
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)

    sql = Scheduler::MediaCleanupScheduler.new.send(:candidates).to_sql
    expect(sql).to include('NOT EXISTS')
    expect(sql).to include('post_draft_media_attachments')
  end
end
