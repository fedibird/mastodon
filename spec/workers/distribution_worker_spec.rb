# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DistributionWorker do
  it 'keeps distributing when one keyword subscription times out' do
    author = Fabricate(:account)
    timed_out_account = Fabricate(:account)
    matched_account = Fabricate(:account)
    status = Fabricate(:status, account: author, text: 'hello bodyword', visibility: :public)
    timed_out = KeywordSubscribe.create!(account: timed_out_account, keyword: 'bodyword', name: 'timeout')
    KeywordSubscribe.create!(account: matched_account, keyword: 'bodyword', name: 'match')

    allow_any_instance_of(KeywordSubscribe).to receive(:keyword_regexp).and_wrap_original do |method|
      if method.receiver.id == timed_out.id
        regexp = instance_double(Regexp)
        allow(regexp).to receive(:match?).and_raise(Regexp::TimeoutError)
        regexp
      else
        method.call
      end
    end

    pushes = []
    allow(FeedInsertWorker).to receive(:push_bulk) do |collection, &block|
      Array(collection).each { |item| pushes << block.call(item) }
    end

    expect { described_class.new.perform(status.id) }.not_to raise_error
    expect(pushes).to include [status.id, matched_account.id, 'home']
    expect(pushes).not_to include [status.id, timed_out_account.id, 'home']
    expect(timed_out.reload.disabled).to be false
  end
end
