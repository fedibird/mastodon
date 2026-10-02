# frozen_string_literal: true

require 'rails_helper'

describe RefreshEmojiReactionCacheWorker do
  subject(:worker) { described_class.new }

  it 'deduplicates refresh jobs with an until-executed lock on the pull queue' do
    options = described_class.get_sidekiq_options

    expect(options['queue']).to eq 'pull'
    expect(options['retry']).to eq 1
    expect(options['dead']).to be false
    expect(options['lock']).to eq :until_executed
  end

  it 'refreshes the grouped emoji reaction cache for an existing status' do
    status = Fabricate(:status)
    expect(status).to receive(:refresh_grouped_emoji_reactions!).once
    allow(Status).to receive(:find).with(status.id).and_return(status)

    worker.perform(status.id)
  end

  it 'does not raise when the status has been deleted' do
    expect(worker.perform(-1)).to be true
  end
end
