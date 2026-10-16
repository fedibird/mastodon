# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Boost notification settings', type: :service do
  let(:account) { Fabricate(:user).account }
  let(:target) { Fabricate(:user).account }

  %i(follow! request_follow!).each do |method|
    it "defaults to off and preserves omitted options for #{method}" do
      relationship = account.public_send(method, target, reblogs: false, delivery: false, notify: true, languages: ['ja'])
      expect(relationship.notify_reblogs).to be false
      relationship = account.public_send(method, target, notify_reblogs: true, delivery: nil)
      expect(relationship.attributes.slice('show_reblogs', 'delivery', 'notify', 'languages', 'notify_reblogs')).to eq(
        'show_reblogs' => false, 'delivery' => false, 'notify' => true, 'languages' => ['ja'], 'notify_reblogs' => true
      )
      expect(account.public_send(method, target, delivery: nil).notify_reblogs).to be true
      expect(account.public_send(method, target, notify_reblogs: false, delivery: nil).notify_reblogs).to be false
    end
  end

  it 'preserves settings through revoke and authorization' do
    follow = account.follow!(target, reblogs: false, notify: true, notify_reblogs: true, delivery: false, languages: ['ja'])
    follow.revoke_request!
    request = account.follow_requests.find_by!(target_account: target)
    expect(request.notify_reblogs).to be true
    request.authorize!
    restored = account.active_relationships.find_by!(target_account: target)
    expect(restored.attributes.slice('show_reblogs', 'notify', 'notify_reblogs', 'delivery', 'languages')).to eq(
      'show_reblogs' => false, 'notify' => true, 'notify_reblogs' => true, 'delivery' => false, 'languages' => ['ja']
    )
  end

  %i(follow! request_follow!).each do |method|
    it "refreshes relationship cache for #{method}" do
      relationship = account.public_send(method, target)
      Rails.cache.delete("relationship:#{account.id}:#{target.id}")
      expect(AccountRelationshipsPresenter.new([target.id], account.id).notifying_reblogs[target.id]).to be_falsey
      relationship.update!(notify_reblogs: true)
      # after_commit does not run within transactional fixtures: exercise the real callback.
      relationship.send(:remove_relationship_cache)
      expect(AccountRelationshipsPresenter.new([target.id], account.id).notifying_reblogs[target.id]).to be true
    end
  end

  it 'refreshes caches written before notifying_reblogs existed' do
    account.follow!(target, notify_reblogs: true)
    Rails.cache.write("relationship:#{account.id}:#{target.id}", { notifying: { target.id => false } })
    expect(AccountRelationshipsPresenter.new([target.id], account.id).notifying_reblogs[target.id]).to be true
  end

  it 'preserves boost opt-in during account migration' do
    account.follow!(target, notify_reblogs: true, delivery: false)
    destination = Fabricate(:user).account
    FollowMigrationService.new.call(account, destination, target)
    expect(account.active_relationships.find_by!(target_account: destination).notify_reblogs).to be true
  end
end
