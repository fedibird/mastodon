# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::Parser::PollParser do
  let(:one_of) do
    {
      'type' => 'Question',
      'oneOf' => [
        { 'name' => 'Yes', 'replies' => { 'totalItems' => 2 } },
        { 'content' => 'No' },
      ],
      'endTime' => '2024-01-02T03:04:05Z',
      'votersCount' => 3,
    }
  end

  let(:any_of) do
    {
      'type' => 'Question',
      'anyOf' => [
        { 'name' => 'Red' },
        { 'name' => 'Blue', 'replies' => { 'totalItems' => 4 } },
      ],
    }
  end

  it 'reads a single-choice poll from oneOf' do
    parser = described_class.new(one_of)

    expect(parser).to be_valid
    expect(parser.multiple).to be false
    expect(parser.options).to eq %w(Yes No)
    expect(parser.cached_tallies).to eq [2, 0]
    expect(parser.voters_count).to eq 3
    expect(parser.expires_at).to eq '2024-01-02T03:04:05Z'.to_datetime
  end

  it 'reads a multiple-choice poll from anyOf' do
    parser = described_class.new(any_of)

    expect(parser).to be_valid
    expect(parser.multiple).to be true
    expect(parser.options).to eq %w(Red Blue)
    expect(parser.cached_tallies).to eq [0, 4]
  end

  it 'uses a closed timestamp, an immediate close, or endTime' do
    closed = described_class.new('type' => 'Question', 'oneOf' => [{ 'name' => 'A' }], 'closed' => '2020-05-06T07:08:09Z')
    open_ended = described_class.new('type' => 'Question', 'oneOf' => [{ 'name' => 'A' }], 'closed' => false, 'endTime' => '2024-01-02T03:04:05Z')
    closing = described_class.new('type' => 'Question', 'oneOf' => [{ 'name' => 'A' }], 'closed' => true)
    invalid = described_class.new('type' => 'Question', 'oneOf' => [{ 'name' => 'A' }], 'endTime' => 'not-a-date')

    expect(closed.expires_at).to eq '2020-05-06T07:08:09Z'.to_datetime
    expect(open_ended.expires_at).to eq '2024-01-02T03:04:05Z'.to_datetime
    expect(closing.expires_at).to be_within(2.seconds).of(Time.now.utc)
    expect(invalid.expires_at).to be_nil
  end

  it 'is invalid without a Question type or an option list' do
    expect(described_class.new('type' => 'Note', 'oneOf' => [{ 'name' => 'A' }])).not_to be_valid
    expect(described_class.new('type' => 'Question')).not_to be_valid
  end

  describe '#significantly_changes?' do
    let(:previous) { Struct.new(:options, :multiple).new(%w(Yes No), false) }

    it 'is false when options and multiple are unchanged' do
      expect(described_class.new(one_of).significantly_changes?(previous)).to be false
    end

    it 'is true when options or multiple change' do
      changed_options = one_of.merge('oneOf' => [{ 'name' => 'Maybe' }])
      changed_multiple = any_of

      expect(described_class.new(changed_options).significantly_changes?(previous)).to be true
      expect(described_class.new(changed_multiple).significantly_changes?(previous)).to be true
    end
  end
end
