require 'rails_helper'

RSpec.describe BatchedRemoveStatusService, '#unpush_from_public_timelines' do
  before { allow(redis).to receive(:publish) }

  it 'skips domain channels for a local public status' do
    status = Fabricate(:status, visibility: :public, text: 'local public')

    described_class.new.call(Status.where(id: status.id))

    expect(redis).to have_received(:publish).with('timeline:public', any_args).at_least(:once)
    expect(redis).not_to have_received(:publish).with(a_string_starting_with('timeline:public:domain:'), any_args)
    expect(redis).not_to have_received(:publish).with('timeline:public:remote', any_args)
  end

  it 'publishes a remote public status on its domain timeline' do
    account = Fabricate(:account, domain: 'example.com', username: 'remote1')
    status = Fabricate(:status, account: account, visibility: :public, text: 'remote public')

    described_class.new.call(Status.where(id: status.id))

    expect(redis).to have_received(:publish).with('timeline:public:domain:example.com', any_args).at_least(:once)
    expect(redis).to have_received(:publish).with('timeline:public:domain:nomedia:example.com', any_args).at_least(:once)
    expect(redis).to have_received(:publish).with('timeline:public:remote', any_args).at_least(:once)
  end
end
