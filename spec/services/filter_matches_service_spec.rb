# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FilterMatchesService do
  let(:viewer) { Fabricate(:user).account }
  let(:author) { Fabricate(:account) }
  let(:service) { described_class.new }

  around do |example|
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = previous
  end

  def matches(*statuses, account: viewer)
    service.call(account, statuses.map { |status| status.id.to_s })
  end

  def filter(keyword = nil, **attributes)
    record = Fabricate(:custom_filter, account: viewer, **attributes)
    Fabricate(:custom_filter_keyword, custom_filter: record, keyword: keyword, whole_word: false) if keyword
    record
  end

  def ids_for(status)
    matches(status)[:matches].fetch(status.id.to_s)
  end

  def serializer_ids(status, relationships: nil)
    serializer = REST::StatusSerializer.new(status, scope: viewer.user, scope_name: :current_user, relationships: relationships)
    serializer.filtered.map { |match| match.filter.id.to_s }
  end

  it 'loads the viewer filter definitions exactly once' do
    statuses = Fabricate.times(3, :status, account: author)
    expect(CustomFilter).to receive(:cached_filters_for).with(viewer.id).once.and_call_original
    matches(*statuses)
  end

  it 'matches the direct serializer and presenter paths, including own posts, actions and contexts' do
    warn_filter = filter('hello', context: ['public'])
    hide_filter = filter('hello', action: :hide, context: ['notifications'])
    [author, viewer].each do |account|
      status = Fabricate(:status, account: account, text: 'HELLO')
      expect(ids_for(status)).to match_array([warn_filter.id.to_s, hide_filter.id.to_s])
      expect(ids_for(status)).to match_array(serializer_ids(status))
      relationships = StatusRelationshipsPresenter.new([status], viewer.id)
      expect(ids_for(status)).to match_array(serializer_ids(status, relationships: relationships))
    end
  end

  it 'combines keyword, wrapper-ID and proper-ID rules without contaminating independently requested originals' do
    original = Fabricate(:status, account: author, text: 'keyword')
    wrapper = Fabricate(:status, reblog: original)
    keyword = filter('keyword')
    wrapper_filter = filter
    proper_filter = filter
    Fabricate(:custom_filter_status, custom_filter: keyword, status: original)
    Fabricate(:custom_filter_status, custom_filter: wrapper_filter, status: wrapper)
    Fabricate(:custom_filter_status, custom_filter: proper_filter, status: original)
    result = matches(wrapper, original)[:matches]
    expect(result[wrapper.id.to_s]).to match_array([keyword.id.to_s, wrapper_filter.id.to_s, proper_filter.id.to_s])
    expect(result[original.id.to_s]).to match_array([keyword.id.to_s, proper_filter.id.to_s])
    [original, wrapper].each do |status|
      expect(result[status.id.to_s]).to match_array(serializer_ids(status))
      presenter = StatusRelationshipsPresenter.new([status], viewer.id)
      expect(result[status.id.to_s]).to match_array(serializer_ids(status, relationships: presenter))
    end
  end

  it 'retains partial, whole-word, case and Japanese matching semantics' do
    partial = filter('cat')
    whole = filter
    Fabricate(:custom_filter_keyword, custom_filter: whole, keyword: 'cat', whole_word: true)
    japanese = filter('東京')
    status = Fabricate(:status, account: author, text: 'CATCH 東京')
    expect(ids_for(status)).to match_array([partial.id.to_s, japanese.id.to_s])
    expect(ids_for(status)).to match_array(serializer_ids(status))
    status.update!(text: 'CAT 東京')
    expect(ids_for(status)).to match_array([partial.id.to_s, whole.id.to_s, japanese.id.to_s])
  end

  it 'uses body, CW, ALT, poll, canonical/display URL and reference URL matching without matching referenced body' do
    status = Fabricate(:status, account: author, text: 'bodyword https://example.com/%E6%9D%B1%E4%BA%AC', spoiler_text: 'cwword')
    Fabricate(:media_attachment, account: author, status: status, description: 'altword')
    poll = Fabricate(:poll, account: author, status: status, options: %w(pollword other))
    status.update!(poll_id: poll.id)
    referenced = Fabricate(:status, account: author, text: 'referencebodyword')
    Fabricate(:status_reference, status: status, target_status: referenced)
    keywords = ['bodyword', 'cwword', 'altword', 'pollword', '%E6%9D%B1%E4%BA%AC', '東京', ActivityPub::TagManager.instance.url_for(referenced)]
    expected = keywords.map { |word| filter(word).id.to_s }
    filter('referencebodyword')
    expect(ids_for(status)).to match_array(expected)
    expect(ids_for(status)).to match_array(serializer_ids(status.reload))
  end

  it 'keeps quote body outside existing matching semantics' do
    quoted = Fabricate(:status, account: author, text: 'quotedword')
    status = Fabricate(:status, account: author, text: 'body', quote: quoted)
    filter('quotedword')
    expect(ids_for(status)).to eq([])
    expect(ids_for(status)).to eq(serializer_ids(status))
  end

  it 'excludes already expired filters and filters expiring while cached' do
    status = Fabricate(:status, text: 'hello')
    filter('hello', expires_at: 1.minute.ago)
    active = filter('hello', expires_at: 1.minute.from_now)
    expect(ids_for(status)).to eq([active.id.to_s])
    travel_to 2.minutes.from_now do
      expect(ids_for(status)).to eq([])
    end
  end

  context 'with real filter caching' do
    it 'invalidates on keyword/status changes, filter deletion and new filter creation' do
      status = Fabricate(:status, text: 'hello')
      expect(ids_for(status)).to eq([])
      record = filter('hello')
      expect(ids_for(status)).to eq([record.id.to_s])
      record.keywords.first.update!(keyword: 'absent')
      expect(ids_for(status)).to eq([])
      rule = Fabricate(:custom_filter_status, custom_filter: record, status: status)
      expect(ids_for(status)).to eq([record.id.to_s])
      other_status = Fabricate(:status)
      rule.update!(status: other_status)
      expect(ids_for(status)).to eq([])
      expect(ids_for(other_status)).to eq([record.id.to_s])
      rule.destroy!
      expect(ids_for(other_status)).to eq([])
      record.keywords.first.update!(keyword: 'hello')
      expect(ids_for(status)).to eq([record.id.to_s])
      record.destroy!
      expect(ids_for(status)).to eq([])
    end
  end

  %w(private direct limited personal).each do |visibility|
    it "hides inaccessible #{visibility} and nonexistent IDs identically" do
      status = Fabricate(:status, account: author, visibility: visibility)
      ids = [status.id.to_s, '9223372036854775807']
      expect(service.call(viewer, ids)).to eq(matches: {}, unavailable: ids)
      expect(matches(status, account: author)[:matches]).to eq(status.id.to_s => [])
    end
  end

  %w(private direct limited).each do |visibility|
    it "allows an explicit mention for #{visibility}" do
      status = Fabricate(:status, account: author, visibility: visibility)
      Fabricate(:mention, account: viewer, status: status)
      expect(ids_for(status)).to eq([])
    end
  end

  it 'allows a follower to see private posts, but not personal posts' do
    viewer.follow!(author)
    private_status = Fabricate(:status, account: author, visibility: :private)
    personal_status = Fabricate(:status, account: author, visibility: :personal)
    result = matches(private_status, personal_status)
    expect(result[:matches]).to eq(private_status.id.to_s => [])
    expect(result[:unavailable]).to eq([personal_status.id.to_s])
  end

  [:block!, :mute!].each do |relationship|
    it "treats #{relationship} authors as unavailable" do
      viewer.public_send(relationship, author)
      status = Fabricate(:status, account: author)
      expect(matches(status)).to eq(matches: {}, unavailable: [status.id.to_s])
    end
  end

  it 'rejects an author blocking the viewer and suspended authors' do
    author.block!(viewer)
    status = Fabricate(:status, account: author)
    expect(matches(status)[:unavailable]).to eq([status.id.to_s])
    author.unblock!(viewer)
    author.suspend!
    expect(matches(status)[:unavailable]).to eq([status.id.to_s])
  end

  it 'checks the original policy even when a public wrapper is visible' do
    original = Fabricate(:status, account: author)
    wrapper = Fabricate(:status, reblog: original)
    original.update!(visibility: :private)
    expect(matches(wrapper)[:unavailable]).to eq([wrapper.id.to_s])
  end

  it 'rejects missing originals, muted originals and domain-blocked remote authors' do
    remote = Fabricate(:account, domain: 'blocked.example')
    remote_status = Fabricate(:status, account: remote)
    Fabricate(:account_domain_block, account: viewer, domain: remote.domain)
    expect(matches(remote_status)[:unavailable]).to eq([remote_status.id.to_s])
    original = Fabricate(:status, account: author)
    wrapper = Fabricate(:status, reblog: original)
    viewer.mute!(author)
    expect(matches(wrapper)[:unavailable]).to eq([wrapper.id.to_s])
    viewer.unmute!(author)
    original.discard
    expect(matches(wrapper)[:unavailable]).to eq([wrapper.id.to_s])
  end

  it 'excludes expired, discarded and page statuses' do
    expired = Fabricate(:status, expired_at: Time.current)
    discarded = Fabricate(:status)
    discarded.discard
    page = Fabricate(:status)
    page.update_columns(ap_object_type: 'page', post_title: 'Page title')
    result = matches(expired, discarded, page)
    expect(result).to eq(matches: {}, unavailable: [expired, discarded, page].map { |status| status.id.to_s })
  end

  it 'does not query or build a status serializer' do
    status = Fabricate(:status)
    expect(REST::StatusSerializer).not_to receive(:new)
    expect(REST::MediaAttachmentSerializer).not_to receive(:new)
    ids_for(status)
  end
end
