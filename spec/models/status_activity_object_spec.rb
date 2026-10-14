# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Status, type: :model do
  let(:alice) { Fabricate(:account, username: 'alice') }

  describe 'activity object attributes' do
    it 'reads an existing status as a note with no title' do
      status = Fabricate(:status, account: alice, text: 'body')

      expect(status.object_type).to eq :note
      expect(status.ap_object_type).to eq 'note'
      expect(status[:ap_object_type]).to be_nil
      expect(status.ap_page?).to be false
      expect(status.post_title).to be_nil
    end

    it 'does not take a title from the body or the content warning' do
      status = Fabricate(:status, account: alice, text: "First line\n\nbody", spoiler_text: 'warning')

      expect(status.post_title).to be_nil
      expect(status.text).to eq "First line\n\nbody"
      expect(status.spoiler_text).to eq 'warning'
    end

    it 'stores a note title without treating it as HTML or as the activity type' do
      title = '<b>日本語</b> 🎉'
      status = Fabricate(:status, account: alice, text: 'body', post_title: "  #{title}  ")

      expect(status.reload.post_title).to eq title
      expect(status[:ap_object_type]).to be_nil
      expect(status.ap_object_type).to eq 'note'
      expect(status.object_type).to eq :note
    end

    it 'stores a blank title as NULL' do
      ['', '   ', "\u3000\u3000"].each do |title|
        status = Fabricate.build(:status, account: alice, post_title: title)
        expect(status).to be_valid
        expect(status.post_title).to be_nil
      end
    end

    it 'rejects line breaks and control characters' do
      ["\n", "\r\n", "\t", "\u0000", "hello\nworld", "\u2028", "\u2029"].each do |title|
        status = Fabricate.build(:status, account: alice, post_title: title)
        expect(status).not_to be_valid
        expect(status.errors[:post_title]).to be_present
      end
    end

    it 'counts Unicode code points separately from the body grapheme limit' do
      expect('👨‍👩‍👧‍👦'.length).to be > '👨‍👩‍👧‍👦'.grapheme_clusters.length

      status = Fabricate.build(:status, account: alice, text: 'a' * StatusLengthValidator::MAX_CHARS, post_title: 'あ' * Status::POST_TITLE_MAX_CODEPOINTS)
      expect(status).to be_valid

      status.post_title = 'あ' * (Status::POST_TITLE_MAX_CODEPOINTS + 1)
      expect(status).not_to be_valid
      expect(status.errors[:post_title]).to be_present

      status.post_title = '題'
      status.text = 'a' * (StatusLengthValidator::MAX_CHARS + 1)
      expect(status).not_to be_valid
      expect(status.errors[:text]).to be_present
    end

    it 'rejects an unknown activity type instead of storing it as a page' do
      status = Fabricate.build(:status, account: alice, ap_object_type: 'Article', post_title: 'Title')

      expect(status).not_to be_valid
      expect(status[:ap_object_type]).to eq 'Article'
      expect(status.ap_page?).to be false
    end

    it 'requires a title for a page and can store that page internally' do
      missing = Fabricate.build(:status, account: alice, ap_object_type: 'page')
      blank = Fabricate.build(:status, account: alice, ap_object_type: 'page', post_title: '   ')
      stored = Fabricate(:status, account: alice, text: 'body', ap_object_type: 'page', post_title: 'Title')

      expect(missing).not_to be_valid
      expect(blank).not_to be_valid
      expect(stored.reload.ap_page?).to be true
      expect(stored[:ap_object_type]).to eq 'page'
      expect(stored.post_title).to eq 'Title'
      expect(stored.object_type).to eq :note
      expect(Status.without_unreleased_pages).to include(Fabricate(:status, account: alice))
      expect(Status.without_unreleased_pages).not_to include(stored)
    end

    it 'rejects a page that is a reply, boost, quote, poll, or remote status' do
      other = Fabricate(:status, account: alice, text: 'other', visibility: :public)
      remote = Fabricate(:account, domain: 'example.com', username: 'remote', uri: 'https://example.com/users/remote')

      expect(Fabricate.build(:status, account: alice, thread: other, ap_object_type: 'page', post_title: 'Title')).not_to be_valid
      expect(Fabricate.build(:status, account: alice, reblog: other, text: '', ap_object_type: 'page', post_title: 'Title')).not_to be_valid
      expect(Fabricate.build(:status, account: alice, quote: other, ap_object_type: 'page', post_title: 'Title')).not_to be_valid
      expect(Fabricate.build(:status, account: remote, text: 'remote', ap_object_type: 'page', post_title: 'Title')).not_to be_valid

      poll_status = Fabricate(:status, account: alice, text: 'vote')
      poll = Fabricate(:poll, account: alice, status: poll_status)
      poll_status.poll_id = poll.id
      poll_status.ap_object_type = 'page'
      poll_status.post_title = 'Title'
      expect(poll_status).not_to be_valid
    end

    it 'keeps a remote status and a reblog as notes' do
      remote_account = Fabricate(:account, domain: 'example.com', username: 'remote2', uri: 'https://example.com/users/remote2')
      remote_status = Fabricate(:status, account: remote_account, text: 'remote body')
      original = Fabricate(:status, account: alice, text: 'original')
      reblog = Fabricate(:status, account: alice, reblog: original, text: '')

      expect(remote_status.ap_object_type).to eq 'note'
      expect(remote_status.post_title).to be_nil
      expect(remote_status.local?).to be false
      expect(reblog.ap_object_type).to eq 'note'
      expect(reblog.post_title).to be_nil
      expect(reblog.object_type).to eq :note
    end

    it 'enforces the shape on writes that skip model validation' do
      status = Fabricate(:status, account: alice)

      expect do
        Status.transaction(requires_new: true) { status.update_columns(ap_object_type: 'page', post_title: nil) }
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect do
        Status.transaction(requires_new: true) { status.update_columns(ap_object_type: 'Article') }
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect do
        Status.transaction(requires_new: true) { status.update_columns(post_title: "bad\n") }
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect { status.update_columns(post_title: 'Stored', ap_object_type: nil) }.not_to raise_error
      expect(status.reload.post_title).to eq 'Stored'
      expect(status[:ap_object_type]).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
