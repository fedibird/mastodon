# frozen_string_literal: true

require 'rails_helper'

# Canonical storage is `:foo::bar:`. Fedibird renders that as two emoji.
# Display transports insert U+200B so Mastodon-compatible clients can do the
# same. Edit source stays canonical.
RSpec.describe 'adjacent custom emoji boundaries' do
  let!(:foo) { Fabricate(:custom_emoji, shortcode: 'foo') }
  let!(:bar) { Fabricate(:custom_emoji, shortcode: 'bar') }
  let(:canonical) { ':foo::bar:' }
  let(:compatible) { ":foo:\u200B:bar:" }
  let!(:user) { Fabricate(:user) }
  let!(:account) do
    user.account.tap do |record|
      record.update!(
        display_name: canonical,
        note: canonical,
        followed_message: canonical,
        fields: [{ 'name' => canonical, 'value' => "see #{canonical}" }]
      )
    end
  end
  let!(:status) do
    record = Fabricate(:status, account: account, text: canonical, spoiler_text: canonical)
    poll = Fabricate(:poll, account: account, status: record, options: [canonical, 'plain'])
    record.update!(poll_id: poll.id)
    record.reload
  end

  def rest_json(record, serializer, **options)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        record,
        { serializer: serializer }.merge(options)
      ).to_json,
      symbolize_names: true
    )
  end

  def activitypub_json(record, serializer)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        record,
        serializer: serializer,
        adapter: ActivityPub::Adapter
      ).to_json
    )
  end

  it 'keeps the canonical text in the database' do
    expect(account.reload.display_name).to eq(canonical)
    expect(account.note).to eq(canonical)
    expect(account.fields.first.name).to eq(canonical)
    expect(status.reload.text).to eq(canonical)
    expect(status.spoiler_text).to eq(canonical)
    expect(status.preloadable_poll.options.first).to eq(canonical)
  end

  it 'extracts both shortcodes' do
    expect(CustomEmoji.from_text(canonical).map(&:shortcode)).to contain_exactly('foo', 'bar')
  end

  it 'renders both images when Fedibird emojifies and does not insert a zero-width space' do
    html = Formatter.instance.format(status, custom_emojify: true)
    name = Formatter.instance.format_display_name(account, custom_emojify: true)

    expect(html.scan(/class="emojione custom-emoji"/).size).to eq(2)
    expect(html).to include('alt=":foo:"', 'alt=":bar:"')
    expect(html).not_to include("\u200B")
    expect(name.scan(/class="emojione custom-emoji"/).size).to eq(2)
    expect(name).not_to include("\u200B")
  end

  it 'leaves shortcodes untouched unless emoji compatibility is requested' do
    html = Formatter.instance.format(status)

    expect(html).to include(canonical)
    expect(html).not_to include("\u200B")
  end

  it 'separates recognized shortcodes in text nodes without rewriting other colon sequences' do
    plain = Fabricate(:status, account: account, text: "2001:db8::1234 foo::bar #{canonical}")
    html = Formatter.instance.format(plain, emoji_compatibility: true)

    expect(html).to include('2001:db8::1234')
    expect(html).to include('foo::bar')
    expect(html).to include(compatible)
    expect(html).not_to include(canonical)
    expect(html).not_to include('<img')
  end

  it 'returns compatible shortcodes from display REST and canonical text from edit source' do
    account_json = rest_json(account, REST::AccountSerializer, scope: user, scope_name: :current_user)
    status_json = rest_json(status, REST::StatusSerializer)
    source_json = rest_json(status, REST::StatusSourceSerializer)
    redraft_json = rest_json(status, REST::StatusSerializer, source_requested: true)

    expect(account_json[:display_name]).to eq(compatible)
    expect(account_json[:note]).to include(compatible)
    expect(account_json[:followed_message]).to include(compatible)
    expect(account_json[:fields].first[:name]).to eq(compatible)
    expect(account_json[:fields].first[:value]).to include(compatible)

    expect(status_json[:content]).to include(compatible)
    expect(status_json[:content]).not_to include(canonical)
    expect(status_json[:spoiler_text]).to eq(compatible)
    expect(status_json[:poll][:options].first[:title]).to eq(compatible)
    expect(status_json[:poll][:options].second[:title]).to eq('plain')

    expect(source_json[:text]).to eq(canonical)
    expect(source_json[:spoiler_text]).to eq(canonical)
    expect(redraft_json[:text]).to eq(canonical)
    expect(redraft_json[:spoiler_text]).to eq(canonical)
    expect(redraft_json).not_to have_key(:content)
  end

  it 'returns compatible shortcodes from ActivityPub actor and note documents' do
    actor = activitypub_json(account, ActivityPub::ActorSerializer)
    note = activitypub_json(status, ActivityPub::NoteSerializer)
    field = actor['attachment'].find { |item| item['type'] == 'PropertyValue' }

    expect(actor['name']).to eq(compatible)
    expect(actor['summary']).to include(compatible)
    expect(actor['_misskey_followedMessage']).to include(compatible)
    expect(field['name']).to eq(compatible)
    expect(field['value']).to include(compatible)

    expect(note['summary']).to eq(compatible)
    expect(note['content']).to include(compatible)
    expect(note['content']).not_to include(canonical)
    expect(note['oneOf'].first['name']).to eq(compatible)
  end

  it 'returns compatible shortcodes from status edit history' do
    edit = StatusEdit.new(status: status, account: account, text: canonical, spoiler_text: canonical, poll_options: [canonical])
    json = rest_json(edit, REST::StatusEditSerializer)

    expect(json[:content]).to include(compatible)
    expect(json[:content]).not_to include(canonical)
    expect(json[:spoiler_text]).to eq(compatible)
    expect(json[:poll][:options].first[:title]).to eq(compatible)
  end
end
