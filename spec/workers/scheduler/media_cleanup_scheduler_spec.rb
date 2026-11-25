require 'rails_helper'

describe Scheduler::MediaCleanupScheduler do
  subject { described_class.new }

  let!(:old_media) { Fabricate(:media_attachment, account_id: nil, created_at: 10.days.ago) }
  let!(:new_media) { Fabricate(:media_attachment, account_id: nil, created_at: 1.hour.ago) }

  it 'removes old media records' do
    subject.perform

    expect { old_media.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(new_media.reload).to be_persisted
  end

  it 'keeps an old file a draft still names, and removes it after the draft is gone' do
    user = Fabricate(:user)
    kept = Fabricate(:media_attachment, account: user.account, created_at: 10.days.ago, description: 'kept alt')
    draft = PostDrafts::Store.new(user.account).create(
      client_uuid: '55555555-5555-4555-8555-555555555555',
      payload: {
        'schema_version' => 1,
        'input' => {
          'text' => 'saved',
          'privacy' => 'personal',
          'media' => [{ 'id' => kept.id.to_s, 'order' => 0, 'description' => 'snapshot alt' }],
        },
      }
    )
    other = Fabricate(:media_attachment, account: user.account, created_at: 10.days.ago)

    subject.perform

    expect(kept.reload.description).to eq 'kept alt'
    expect(PostDraftMediaAttachment.exists?(media_attachment_id: kept.id)).to be true
    expect { other.reload }.to raise_error(ActiveRecord::RecordNotFound)

    expect(kept.destroy).to eq false
    expect(MediaAttachment.exists?(kept.id)).to be true

    PostDrafts::Store.new(user.account).destroy(draft.draft.id, expected_revision: 1)
    expect(MediaAttachment.exists?(kept.id)).to be true
    subject.perform
    expect { kept.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'does not delete a candidate that gained a draft reference after it was selected' do
    user = Fabricate(:user)
    media = Fabricate(:media_attachment, account: user.account, created_at: 10.days.ago)
    PostDrafts::Store.new(user.account).create(
      client_uuid: '66666666-6666-4666-8666-666666666666',
      payload: {
        'schema_version' => 1,
        'input' => { 'text' => 'saved', 'media' => [{ 'id' => media.id.to_s }] },
      }
    )
    allow(subject).to receive(:candidates).and_return(MediaAttachment.where(id: media.id))

    subject.perform

    expect(MediaAttachment.exists?(media.id)).to be true
    expect(PostDraftMediaAttachment.exists?(media_attachment_id: media.id)).to be true
  end
end
