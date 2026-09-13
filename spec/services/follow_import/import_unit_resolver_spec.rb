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
    stub_csv("Account address,Show boosts,Notify on new posts\nbob,true,false\neve@remote.test,false,true")

    map = resolver.work_by_key_hash

    bob = map[FollowImportTarget.key_hash('bob')]
    eve = map[FollowImportTarget.key_hash('eve@remote.test')]

    expect(bob[:acct]).to eq 'bob'
    expect(bob[:options][:show_reblogs]).to eq 'true'
    expect(bob[:options][:notify]).to eq 'false'
    expect(eve[:acct]).to eq 'eve@remote.test'
    expect(eve[:options][:show_reblogs]).to eq 'false'
    expect(eve[:options][:notify]).to eq 'true'
  end

  it 'applies field defaults when columns are absent' do
    stub_csv("Account address\nbob")

    work = resolver.work_by_key_hash[FollowImportTarget.key_hash('bob')]

    expect(work[:options][:show_reblogs]).to be true
    expect(work[:options][:notify]).to be false
    expect(work[:options][:delivery]).to be true
    expect(work[:options][:languages]).to be_nil
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
