# frozen_string_literal: true

require 'rails_helper'

describe 'ActivityPub parser autoload' do
  it 'resolves the parser namespace and forwarder through Zeitwerk' do
    expect(ActivityPub::Parser::StatusParser.name).to eq 'ActivityPub::Parser::StatusParser'
    expect(ActivityPub::Parser::PollParser.name).to eq 'ActivityPub::Parser::PollParser'
    expect(ActivityPub::Parser::MediaAttachmentParser.name).to eq 'ActivityPub::Parser::MediaAttachmentParser'
    expect(ActivityPub::Parser::CustomEmojiParser.name).to eq 'ActivityPub::Parser::CustomEmojiParser'
    expect(ActivityPub::Forwarder.name).to eq 'ActivityPub::Forwarder'
    expect(ActivityPub::Parser.name).to eq 'ActivityPub::Parser'

    expect(Object.const_source_location('ActivityPub::Parser::StatusParser').first).to end_with('app/lib/activitypub/parser/status_parser.rb')
    expect(Object.const_source_location('ActivityPub::Forwarder').first).to end_with('app/lib/activitypub/forwarder.rb')
  end
end
