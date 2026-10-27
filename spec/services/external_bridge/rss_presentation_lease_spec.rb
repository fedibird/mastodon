# frozen_string_literal: true

# The rows have to be committed so a second connection can lock or claim them.
# rubocop:disable Metrics/BlockLength

require 'rails_helper'

RSpec.describe 'RSS presentation lease', type: :model do
  self.use_transactional_tests = false

  after do
    cleanup!
  end

  def cleanup!
    return if @user.nil?

    source_id = @source_id
    ExternalBridge::DeleteUser.call(User.find(@user.id)) if User.exists?(@user.id)
    ExternalResource.where(external_source_id: source_id).delete_all if source_id
    ExternalSource.where(id: source_id).delete_all if source_id
    Account.where(id: @user.account_id).destroy_all
  ensure
    @user = nil
  end

  it 'gives an expired lease to only one of two racing claims' do
    @user = Fabricate(:user)
    enable_external_bridge_rss!(@user)
    world = project_for(@user)
    @source_id = world[:source].id
    world[:subscription].update_columns(
      cw_enabled: true,
      presentation_revision: 3,
      presentation_applied_revision: 0,
      presentation_lease_token: 'expired',
      presentation_lease_until: 1.hour.ago
    )

    tokens = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          tokens << ExternalBridge::RSS::PresentationReconcileWorker.claim(world[:subscription].id, 3)
        end
      end
    end
    threads.each(&:join)
    won = Array.new(tokens.size) { tokens.pop }.compact

    expect(won.size).to eq(1)
    expect(world[:subscription].reload.presentation_lease_token).to eq(won.first)

    bumps = 0
    allow(ExternalBridge::Streaming::Scheduler).to receive(:bump_and_schedule_content!) { bumps += 1 }
    writers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ExternalBridge::RSS::PresentationReconcileWorker.new.perform(world[:subscription].id, 3, 0, won.first)
        end
      end
    end
    writers.each(&:join)

    expect(world[:status].reload.spoiler_text).to eq('Imported title')
    expect(bumps).to eq(1)
    expect(ExternalBridge::RSS::PresentationReconcileWorker.claim(world[:subscription].id, 3)).to be_nil
  end

  it 'sees a choice saved by the lock holder and does not write another generation' do
    @user = Fabricate(:user)
    enable_external_bridge_rss!(@user)
    world = project_for(@user)
    @source_id = world[:source].id
    world[:subscription].update_columns(cw_enabled: false, presentation_revision: 4, presentation_applied_revision: 4)
    ready = Queue.new
    release = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ExternalSubscription.transaction do
          ExternalSubscription.lock.find(world[:subscription].id)
          ready << :locked
          release.pop
          ExternalSubscription.where(id: world[:subscription].id).update_all(
            cw_enabled: true,
            presentation_revision: 8,
            presentation_applied_revision: 8,
            presentation_lease_token: nil,
            presentation_lease_until: nil
          )
        end
      end
    end

    ready.pop
    updater = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ExternalBridge::RSS::PresentationUpdate.new.call(
          user: @user,
          subscription_id: world[:subscription].id,
          cw_enabled: true
        )
      end
    end
    sleep 0.2
    release << :go
    holder.join
    saved = updater.value

    expect(saved.presentation_revision).to eq(8)
    expect(saved.cw_enabled).to eq(true)
    expect(world[:status].reload.spoiler_text).to eq('')
  end
end

# rubocop:enable Metrics/BlockLength
