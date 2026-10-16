# frozen_string_literal: true

require 'rails_helper'

describe StatusLengthValidator do
  describe '#validate' do
    it 'does not add errors onto remote statuses' do
      status = double(local?: false)
      subject.validate(status)
      expect(status).not_to receive(:errors)
    end

    it 'does not add errors onto local reblogs' do
      status = double(local?: false, reblog?: true)
      subject.validate(status)
      expect(status).not_to receive(:errors)
    end

    it 'adds an error when content warning is over 500 characters' do
      status = double(spoiler_text: 'a' * 520, text: '', errors: double(add: nil), local?: true, reblog?: false)
      subject.validate(status)
      expect(status.errors).to have_received(:add)
    end

    it 'adds an error when text is over 500 characters' do
      status = double(spoiler_text: '', text: 'a' * 520, errors: double(add: nil), local?: true, reblog?: false)
      subject.validate(status)
      expect(status.errors).to have_received(:add)
    end

    it 'adds an error when text and content warning are over 500 characters total' do
      status = double(spoiler_text: 'a' * 250, text: 'b' * 251, errors: double(add: nil), local?: true, reblog?: false)
      subject.validate(status)
      expect(status.errors).to have_received(:add)
    end

    [" ", "\t", "\n", "　"].each do |whitespace|
      [StatusLengthValidator::MAX_CHARS, StatusLengthValidator::MAX_CHARS + 1].each do |length|
        it "counts #{length} authored whitespace characters #{whitespace.inspect}" do
          text = whitespace * length
          status = double(spoiler_text: '', text: text, errors: double(add: nil), local?: true, reblog?: false)

          subject.validate(status)

          if length > StatusLengthValidator::MAX_CHARS
            expect(status.errors).to have_received(:add)
          else
            expect(status.errors).not_to have_received(:add)
          end
          expect(status.text).to eq(whitespace * length)
        end
      end
    end

    it 'includes whitespace-only body text in the combined content warning limit' do
      status = double(spoiler_text: 'a', text: ' ' * StatusLengthValidator::MAX_CHARS, errors: double(add: nil), local?: true, reblog?: false)

      subject.validate(status)

      expect(status.errors).to have_received(:add)
    end

    it 'accepts a nil body without changing it' do
      status = double(spoiler_text: '', text: nil, errors: double(add: nil), local?: true, reblog?: false)

      subject.validate(status)

      expect(status.errors).not_to have_received(:add)
      expect(status.text).to be_nil
    end

    it 'counts URLs as 23 characters flat' do
      text   = ('a' * 476) + " http://#{'b' * 30}.com/example"
      status = double(spoiler_text: '', text: text, errors: double(add: nil), local?: true, reblog?: false)

      subject.validate(status)
      expect(status.errors).to_not have_received(:add)
    end

    it 'does not count non-autolinkable URLs as 23 characters flat' do
      text   = ('a' * 476) + "http://#{'b' * 30}.com/example"
      status = double(spoiler_text: '', text: text, errors: double(add: nil), local?: true, reblog?: false)

      subject.validate(status)
      expect(status.errors).to have_received(:add)
    end

    it 'does not count overly long URLs as 23 characters flat' do
      text = "http://example.com/valid?#{'#foo?' * 1000}"
      status = double(spoiler_text: '', text: text, errors: double(add: nil), local?: true, reblog?: false)
      subject.validate(status)
      expect(status.errors).to have_received(:add)
    end

    it 'counts only the front part of remote usernames' do
      text   = ('a' * 475) + " @alice@#{'b' * 30}.com"
      status = double(spoiler_text: '', text: text, errors: double(add: nil), local?: true, reblog?: false)

      subject.validate(status)
      expect(status.errors).to_not have_received(:add)
    end

    it 'does count both parts of remote usernames for overly long domains' do
      text   = "@alice@#{'b' * 500}.com"
      status = double(spoiler_text: '', text: text, errors: double(add: nil), local?: true, reblog?: false)

      subject.validate(status)
      expect(status.errors).to have_received(:add)
    end
  end
end
