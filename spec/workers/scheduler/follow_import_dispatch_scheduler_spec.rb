# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::FollowImportDispatchScheduler do
  subject(:worker) { described_class.new }

  it 'uses retry 0 and a Sidekiq unique lock that is only job deduplication' do
    expect(described_class.get_sidekiq_options['retry']).to eq 0
    expect(described_class.get_sidekiq_options['lock']).to eq :until_executed
  end

  it 'delegates to FollowImport::DispatchScheduler' do
    result = FollowImport::DispatchScheduler::Result.new(
      outcome: 'shadow_disabled',
      lease_acquired: false,
      plan: nil,
      tick_id: 'tick'
    )
    scheduler = instance_double(FollowImport::DispatchScheduler, call: result)
    allow(FollowImport::DispatchScheduler).to receive(:new).and_return(scheduler)

    expect(worker.perform).to eq result
    expect(scheduler).to have_received(:call)
  end

  it 'does not claim or enqueue when invoked with the default-off flag' do
    allow(Import::RelationshipWorker).to receive(:perform_async)
    batch = FollowImportBatch.create!(subject: Fabricate(:moderation_subject), imported_at: Time.now.utc,
                                      mode: :merge, target_count: 0, resolved_target_count: 0, unresolved_target_count: 0)
    target = batch.targets.create!(target_key_hash: 'worker-shadow', position: 0)

    worker.perform

    expect(target.reload.state).to eq 'pending'
    expect(Import::RelationshipWorker).not_to have_received(:perform_async)
    expect(FollowImportDispatchTickObservation.count).to eq 0
  end
end
