# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostStatusService do
  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }

  def writes_during(&block)
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql]
    end
    result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    writes = queries.select { |sql| sql.start_with?('INSERT', 'UPDATE') && sql.include?('"statuses"') }
    [result, writes]
  end

  it 'stores emoji identities in the insert and does not update the row again' do
    plain, plain_writes = writes_during do
      described_class.new.call(user.account, text: 'hello', visibility: 'public')
    end
    emoji = Fabricate(:custom_emoji, shortcode: 'blob')
    with_emoji, emoji_writes = writes_during do
      described_class.new.call(user.account, text: 'hello :blob:', visibility: 'public')
    end
    choice = Fabricate(:custom_emoji, shortcode: 'choice')
    with_poll, poll_writes = writes_during do
      described_class.new.call(
        user.account,
        text: 'vote',
        visibility: 'public',
        poll: { options: ['Yes :choice:', 'No'], expires_in: 1.day.to_i }
      )
    end

    [plain_writes, emoji_writes, poll_writes].each do |writes|
      expect(writes.count { |sql| sql.start_with?('INSERT') }).to eq(1)
      expect(writes.grep(/emoji_identities/).size).to eq(1)
      expect(writes.grep(/emoji_identities/)).to all(start_with('INSERT'))
    end
    expect(plain.emoji_identities).to eq []
    expect(with_emoji.emoji_identities).to include(hash_including('id' => emoji.id.to_s, 'shortcode' => 'blob'))
    expect(with_poll.emoji_identities).to include(hash_including('id' => choice.id.to_s, 'shortcode' => 'choice'))
  end
end
