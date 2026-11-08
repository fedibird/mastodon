# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'Emoji mute collection consistency' do
  self.use_transactional_tests = false

  let(:user) { Fabricate(:user) }

  before do
    ActiveRecord::Base.connection_pool.lock_thread = false
  end

  after do
    EmojiMute.where(user_id: user.id).delete_all
    EmojiMuteCollection.where(user_id: user.id).delete_all
    user.destroy!
    ActiveRecord::Base.connection_pool.lock_thread = true
    EmojiMutes::Repository.before_revision_read = nil
  end

  def create_native(native, owner = user)
    EmojiMutes::Repository.new(owner).create({
      'emoji' => { 'kind' => 'unicode', 'native' => native },
    })
  end

  it 'lets two different first creates succeed and returns one conflict for the same native' do
    start = Queue.new
    different = %w[😀 🎉].map do |native|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          create_native(native, User.find(user.id))
          :ok
        rescue EmojiMutes::Conflict
          :conflict
        end
      end
    end
    2.times { start << true }
    expect(different.map { |thread| thread.value }).to contain_exactly(:ok, :ok)
    expect(EmojiMute.where(user_id: user.id).count).to eq 2
    expect(EmojiMuteCollection.find_by!(user_id: user.id).revision).to eq 2

    start = Queue.new
    same = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          create_native('👍', User.find(user.id))
          :ok
        rescue EmojiMutes::Conflict
          :conflict
        end
      end
    end
    2.times { start << true }
    expect(same.map { |thread| thread.value }).to contain_exactly(:ok, :conflict)
    expect(EmojiMute.where(user_id: user.id, native: '👍').count).to eq 1
  end

  it 'does not attach a newer revision to the rules read before that update' do
    create_native('😀')
    held = Queue.new
    release = Queue.new
    reader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        EmojiMutes::Repository.before_revision_read = lambda {
          held << true
          Timeout.timeout(10) { release.pop }
        }
        mutes, revision = EmojiMutes::Repository.consistent_state(user.id)
        [mutes.map(&:native), revision]
      end
    end
    Timeout.timeout(10) { held.pop }
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        create_native('🎉', User.find(user.id))
      end
    end
    sleep 0.2
    expect(writer.alive?).to be true
    expect(EmojiMute.where(user_id: user.id).pluck(:native)).to eq ['😀']
    release << true
    expect(reader.value).to eq [['😀'], 1]
    expect(writer.join(10)).to be_present
    expect(writer.value.fetch('revision')).to eq '2'
    list = EmojiMutes::Repository.new(User.find(user.id)).list
    expect(list.fetch('revision')).to eq '2'
    expect(list.fetch('emoji_mutes').map { |row| row.dig('emoji', 'native') }).to contain_exactly('😀', '🎉')
  end
end
