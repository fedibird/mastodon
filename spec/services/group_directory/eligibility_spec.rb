# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::Eligibility do
  def directory_group(username, domain: nil, **options)
    local_user = domain.nil? ? Fabricate(:user, confirmed_at: 10.days.ago, approved: true) : nil
    account = Fabricate(:account, {
      username: username,
      domain: domain,
      actor_type: 'Group',
      discoverable: true,
      user: local_user,
    }.merge(options))
    account.create_account_stat! unless options[:skip_stat]
    account
  end

  def directory_node(domain, software, nodeinfo: { 'ok' => true })
    Node.create!(
      domain: domain,
      info: software.nil? ? {} : { 'software_name' => software },
      nodeinfo: nodeinfo
    )
  end

  it 'lists the same groups as the directory scope and keeps the default API on SQL' do
    directory_node('lemmy.example', 'Lemmy')
    directory_node('video.example', 'PeerTube')
    directory_node('blank.example', '   ')
    directory_node('missing.example', 'lemmy', nodeinfo: { 'error' => 'missing' })
    directory_node('guppe.example', 'guppe')
    local = directory_group('local_group')
    lemmy = directory_group('lemmy_group', domain: 'lemmy.example')
    blank = directory_group('blank_group', domain: 'blank.example')
    guppe = directory_group('guppe_group', domain: 'guppe.example')
    peertube = directory_group('channel', domain: 'video.example')
    missing = directory_group('missing_group', domain: 'missing.example')
    orphan = directory_group('orphan_group', domain: 'orphan.example')
    person = directory_group('person_not_group', domain: 'lemmy.example', actor_type: 'Person')
    hidden = directory_group('hidden_group', discoverable: false)
    suspended = directory_group('suspended_group', suspended: true)
    silenced = directory_group('silenced_group', silenced: true)
    moved = directory_group('moved_group')
    moved.update!(moved_to_account: directory_group('moved_target'))
    unapproved = directory_group('unapproved_group')
    unapproved.user.update!(approved: false)
    statless = Fabricate(:account, username: 'statless_group', actor_type: 'Group', discoverable: true, user: Fabricate(:user, confirmed_at: 10.days.ago, approved: true))

    listed = [local, lemmy, blank, guppe]
    rejected = [peertube, missing, orphan, person, hidden, suspended, silenced, moved, unapproved, statless]

    expect(listed.map { |account| described_class.eligible?(account.reload) }).to all(be true)
    expect(rejected.map { |account| described_class.eligible?(account.reload) }).to all(be false)

    ids = (listed + rejected).map(&:id)
    expect(described_class.scope.where(id: ids).pluck(:id)).to match_array(listed.map(&:id))

    seen = []
    described_class.scope.where(id: local.id).find_in_batches { |batch| seen.concat(batch.map(&:id)) }
    expect(seen).to eq([local.id])

    sql = GroupDirectory::Query.new(viewer: nil, params: { q: 'photo' }, limit: 5).results.to_sql
    expect(sql).to include('ILIKE')
    controller = File.read(Rails.root.join('app/controllers/api/v1/group_directories_controller.rb'))
    listing = File.read(Rails.root.join('app/services/group_directory/listing.rb'))
    expect(controller).to include('GroupDirectory::Listing')
    expect(controller).not_to include('GroupDirectoryIndex')
    expect(listing).to include('GroupDirectory::Query')
    expect(listing).to include('GROUP_DIRECTORY_ES_SEARCH')
    expect(GroupDirectory::Readiness.search_enabled?).to be false
  end

  it 'keeps a managed local group with no login and classifies software buckets' do
    requester = Fabricate(:user)
    request = GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'managedonly',
      display_name: 'Managed',
      note: 'A place'
    )
    group = Fabricate(:account, username: 'managedonly', actor_type: 'Group', discoverable: true)
    group.create_account_stat!
    ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request)

    expect(group.user).to be_nil
    expect(described_class.eligible?(group.reload)).to be true
    expect(described_class.scope.where(id: group.id)).to exist
    expect(GroupDirectory::Document.software_bucket(group)).to eq('fedibird')
    expect(GroupDirectory::Document.domain_key(group)).to eq('')

    directory_node('bird.example', 'FediBird')
    directory_node('other.example', 'guppe')
    fedibird = directory_group('bird_group', domain: 'bird.example')
    other = directory_group('other_group', domain: 'other.example')
    expect(GroupDirectory::Document.software_bucket(fedibird)).to eq('fedibird')
    expect(GroupDirectory::Document.software_name(fedibird)).to eq('fedibird')
    expect(GroupDirectory::Document.software_bucket(other)).to eq('other')
    expect(GroupDirectory::Document.software_name(other)).to eq('guppe')
  end

  it 'caps indexed text and does not copy NodeInfo languages or replace a null activity time' do
    directory_node('lemmy.example', nil, nodeinfo: { 'ok' => true })
    Node.find_by(domain: 'lemmy.example').update!(info: { 'software_name' => '', 'languages' => ['ja'] })
    remote = directory_group('long_group', domain: 'lemmy.example', display_name: 'KeepName', note: "#{'n' * 3_000}TAILMARKER")

    expect(GroupDirectory::Document.plain_note(remote).length).to eq(GroupDirectory::Document::NOTE_LIMIT)
    expect(GroupDirectory::Document.plain_note(remote)).not_to include('TAILMARKER')
    expect(GroupDirectory::Document.search_text(remote)).to start_with('KeepName')
    expect(GroupDirectory::Document.search_text(remote)).not_to include('TAILMARKER')
    expect(GroupDirectory::Document.search_text(remote).length).to be <= GroupDirectory::Document::SEARCH_TEXT_LIMIT
    expect(GroupDirectory::Document.language_tags(remote)).to eq([])
    expect(GroupDirectory::Document.software_bucket(remote)).to eq('unknown')
    expect(GroupDirectory::Document.last_status_at(remote)).to be_nil

    stamped = 2.hours.ago.change(usec: 0)
    remote.account_stat.update!(last_status_at: stamped)
    expect(GroupDirectory::Document.last_status_at(remote.reload)).to be_within(1.second).of(stamped)
  end
end
