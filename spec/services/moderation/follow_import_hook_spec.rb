require 'rails_helper'

# Integration: a real following import records a FollowImportBatch (and its
# targets) before the follows are executed.
RSpec.describe 'Follow import moderation hook', type: :service do
  include RoutingHelper

  let!(:account) { Fabricate(:account, locked: false) }
  let!(:bob)     { Fabricate(:account, username: 'bob', locked: false) }
  let!(:eve)     { Fabricate(:account, username: 'eve', domain: 'example.com', locked: false, protocol: :activitypub, inbox_url: 'https://example.com/inbox') }
  let(:csv)      { attachment_fixture('mute-imports.txt') }
  let(:import)   { Import.create(account: account, type: 'following', data: csv) }

  before { stub_request(:post, 'https://example.com/inbox').to_return(status: 200) }

  it 'records a follow import batch with resolved targets' do
    expect { ImportService.new.call(import) }.to change(FollowImportBatch, :count).by(1)

    batch = FollowImportBatch.last
    expect(batch.subject.account_id).to eq account.id
    expect(batch.target_count).to eq 2
    expect(batch.resolved_target_count).to eq 2
    expect(batch.targets.count).to eq 2
    expect(batch.targets.filter_map { |t| t.target_subject&.account_id }).to match_array([bob.id, eve.id])
  end
end
