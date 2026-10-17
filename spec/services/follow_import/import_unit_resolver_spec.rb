# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::ImportUnitResolver do
  let(:account) { Fabricate(:account) }
  let(:import)  { Import.new(account: account, type: 'following') }

  subject(:resolver) { described_class.new(import) }

  def stub_csv(text)
    allow(resolver).to receive(:csv_text).and_return(text)
  end

  it 'recovers acct and follow options keyed by the canonical target key hash' do
    stub_csv("Account address,Show boosts,Notify on new posts,Notify on boosts,Languages,Delivery to home\nbob,true,false,true,\"en, ja\",false\neve@remote.test,false,true,false,,true")

    map = resolver.work_by_key_hash

    bob = map[FollowImportTarget.key_hash('bob')]
    eve = map[FollowImportTarget.key_hash('eve@remote.test')]

    expect(bob[:acct]).to eq 'bob'
    expect(bob[:options]).to eq(reblogs: true, notify: false, notify_reblogs: true, languages: %w(en ja), delivery: false)
    expect(eve[:acct]).to eq 'eve@remote.test'
    expect(eve[:options]).to eq(reblogs: false, notify: true, notify_reblogs: false, languages: nil, delivery: true)
    expect(bob[:options][:notify_reblogs]).to be true
    expect(eve[:options][:notify_reblogs]).to be false
  end

  it 'applies field defaults when columns are absent' do
    stub_csv("Account address\nbob")

    work = resolver.work_by_key_hash[FollowImportTarget.key_hash('bob')]

    expect(work[:options][:reblogs]).to be true
    expect(work[:options][:notify]).to be false
    expect(work[:options][:notify_reblogs]).to be false
    expect(work[:options][:delivery]).to be true
    expect(work[:options][:languages]).to be_nil
  end

  it 'treats a blank Notify on boosts cell as false and does not keep the string false' do
    stub_csv("Account address,Notify on boosts\nblank,\nword,false\nupper,FALSE")

    options = ->(acct) { resolver.work_by_key_hash[FollowImportTarget.key_hash(acct)][:options] }

    expect(options.call('blank')[:notify_reblogs]).to be false
    expect(options.call('word')[:notify_reblogs]).to be false
    expect(options.call('upper')[:notify_reblogs]).to be false
  end

  it 'deduplicates addresses on the canonical key, matching the recorder' do
    stub_csv("Account address\nbob\nBob\nbob@#{Rails.configuration.x.local_domain}")

    map = resolver.work_by_key_hash

    expect(map.size).to eq 1
    expect(map).to have_key(FollowImportTarget.key_hash('bob'))
  end

  it 'looks up recovered work for a specific target by its key hash' do
    stub_csv("Account address\neve@remote.test")
    target = FollowImportTarget.new(target_key_hash: FollowImportTarget.key_hash('eve@remote.test'))

    expect(resolver.work_for(target)[:acct]).to eq 'eve@remote.test'
  end

  it 'returns an empty map when there is no import' do
    expect(described_class.new(nil).work_by_key_hash).to eq({})
  end
end
