# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'REST and ActivityPub mixed media serialization' do
  let(:account) { Fabricate(:account, username: 'mediaowner') }
  let(:status) { Fabricate(:status, account: account, text: 'mixed', visibility: :public) }

  def store_media(record, type, name)
    MediaAttachment.new(
      account: record.account,
      status: record,
      type: type,
      remote_url: "https://cdn.example/#{name}",
      description: name,
      file_file_name: "#{name}.bin",
      file_content_type: 'application/octet-stream',
      file_file_size: 10
    ).tap { |media| media.save!(validate: false) }
  end

  def attach_in_order(record, pairs)
    media = pairs.map { |type, name| store_media(record, type, name) }
    record.update!(ordered_media_attachment_ids: media.map(&:id))
    record.reload
  end

  def rest_json(record, serializer: REST::StatusSerializer, **options)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        record,
        serializer: serializer,
        adapter: :attributes,
        scope: nil,
        scope_name: :current_user,
        **options
      ).to_json
    )
  end

  let(:kinds) { [%i(image photo-a), %i(video clip-a), %i(image photo-b), %i(video clip-b), %i(audio talk)] }

  before do
    attach_in_order(status, kinds)
  end

  def media_names(json)
    json.fetch('media_attachments').map { |item| item.fetch('description') }
  end

  it 'returns every attachment, in order, with the existing media fields' do
    json = rest_json(status)

    expect(media_names(json)).to eq(%w(photo-a clip-a photo-b clip-b talk))
    expect(json.fetch('media_attachments').map { |item| item.fetch('type') }).to eq(%w(image video image video audio))
    expect(json.fetch('media_attachments').first.keys).to contain_exactly(
      'id', 'type', 'url', 'preview_url', 'remote_url', 'preview_remote_url', 'text_url', 'meta', 'description', 'blurhash', 'thumbhash'
    )
    expect(json).not_to have_key('fedibird_external')
  end

  it 'keeps the full list on a nested quote and a nested reblog' do
    parent = Fabricate(:status, account: account, text: 'quotes it', visibility: :public, quote: status)
    reblog = Fabricate(:status, account: Fabricate(:account, username: 'booster'), visibility: :public, reblog: status)

    expect(media_names(rest_json(parent).fetch('quote'))).to eq(%w(photo-a clip-a photo-b clip-b talk))
    expect(media_names(rest_json(reblog).fetch('reblog'))).to eq(%w(photo-a clip-a photo-b clip-b talk))
  end

  it 'keeps the full list in compact statuses and referenced quotes or reblogs' do
    parent = Fabricate(:status, account: account, text: 'quotes it', visibility: :public, quote: status)
    reblog = Fabricate(:status, account: Fabricate(:account, username: 'booster'), visibility: :public, reblog: status)
    presenter = CompactStatusesPresenter.new(statuses: [parent, reblog])
    json = rest_json(presenter, serializer: REST::CompactStatusesSerializer)

    compact_parent = json.fetch('statuses').find { |row| row.fetch('id') == parent.id.to_s }
    compact_reblog = json.fetch('statuses').find { |row| row.fetch('id') == reblog.id.to_s }
    referenced = json.fetch('referenced_statuses').find { |row| row.fetch('id') == status.id.to_s }

    expect(compact_parent.fetch('quote')).to eq(status.id.to_s)
    expect(compact_reblog.fetch('reblog')).to eq(status.id.to_s)
    expect(media_names(referenced)).to eq(%w(photo-a clip-a photo-b clip-b talk))
    expect(referenced.fetch('account')).to eq(account.id.to_s)
  end

  it 'keeps the full list on an edit snapshot and an ActivityPub note' do
    status.snapshot!
    edit_json = rest_json(status.edits.last, serializer: REST::StatusEditSerializer)
    note = JSON.parse(
      ActiveModelSerializers::SerializableResource.new(status, serializer: ActivityPub::NoteSerializer, adapter: ActivityPub::Adapter).to_json
    )

    expect(media_names(edit_json)).to eq(%w(photo-a clip-a photo-b clip-b talk))
    expect(note.fetch('attachment').map { |item| item.fetch('url') }).to eq(status.ordered_media_attachments.map(&:remote_url))
    expect(note.fetch('attachment').size).to eq(5)
  end

  it 'returns an empty media list when there are no attachments' do
    empty = Fabricate(:status, account: account, text: 'plain', visibility: :public)

    expect(rest_json(empty).fetch('media_attachments')).to eq([])
  end
end
