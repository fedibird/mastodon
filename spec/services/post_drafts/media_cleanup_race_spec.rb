# frozen_string_literal: true

require 'rails_helper'

describe 'draft media cleanup race' do
  self.use_transactional_tests = false

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def cleanup_user(user)
    return if user&.id.nil?

    PostDraft.where(account_id: user.account_id).delete_all
    MediaAttachment.where(account_id: user.account_id).find_each(&:destroy!)
    user.session_activations.delete_all
    account_id = user.account_id
    user.destroy!
    Account.where(id: account_id).find_each(&:destroy!)
  end

  it 'does not destroy a file that is still linked when cleanup and save overlap' do
    user = Fabricate(:user)
    errors = []
    barrier = Mutex.new
    4.times do |index|
      media = Fabricate(:media_attachment, account: user.account, created_at: 10.days.ago)
      threads = [Scheduler::MediaCleanupScheduler.new, nil].map.with_index do |_worker, worker_index|
        Thread.new do
          with_connection do
            if worker_index.zero?
              Scheduler::MediaCleanupScheduler.new.perform
            else
              PostDrafts::Store.new(Account.find(user.account_id)).create(
                client_uuid: format('abababab-abab-4bab-8bab-%012d', index),
                payload: {
                  'schema_version' => 1,
                  'input' => { 'text' => "race #{index}", 'media' => [{ 'id' => media.id.to_s }] },
                }
              )
            end
          end
        rescue StandardError => e
          barrier.synchronize { errors << e }
        end
      end
      unfinished = threads.count { |thread| thread.join(20).nil? }

      expect(unfinished).to eq 0
      expect(errors).to be_empty
      expect(MediaAttachment.exists?(media.id)).to be true if PostDraftMediaAttachment.exists?(media_attachment_id: media.id)
    end
  ensure
    cleanup_user(user)
  end
end
