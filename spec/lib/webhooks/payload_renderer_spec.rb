# frozen_string_literal: true

require 'rails_helper'

describe Webhooks::PayloadRenderer do
  subject(:renderer) { described_class.new(json) }

  describe '#render' do
    let(:json) do
      Oj.dump(
        event: 'status.created',
        object: {
          username: 'alice',
          display_name: 'Foo"',
          statuses: [{ id: '42' }],
        }
      )
    end

    it 'renders a scalar' do
      expect(renderer.render('{{event}}')).to eq 'status.created'
    end

    it 'renders a nested property' do
      expect(renderer.render('{{object.username}}')).to eq 'alice'
    end

    it 'renders an array index' do
      expect(renderer.render('{{object.statuses.0.id}}')).to eq '42'
    end

    it 'embeds a string inside surrounding text' do
      expect(renderer.render('hello {{object.username}}!')).to eq 'hello alice!'
    end

    it 'escapes string values for use in JSON' do
      expect(renderer.render('foo={{object.display_name}}')).to eq 'foo=Foo\\"'
    end

    context 'when event is account.approved' do
      let(:event)   { Webhooks::EventPresenter.new(type, object) }
      let(:payload) { ActiveModelSerializers::SerializableResource.new(event, serializer: REST::Admin::WebhookEventSerializer, scope: nil, scope_name: :current_user).as_json }
      let(:json)    { Oj.dump(payload) }
      let(:type)    { 'account.approved' }
      let(:object)  { Fabricate(:account, display_name: 'Foo"') }

      it 'renders event-related variables into template' do
        expect(renderer.render('foo={{event}}')).to eq 'foo=account.approved'
      end

      it 'renders event-specific variables into template' do
        expect(renderer.render('foo={{object.username}}')).to eq "foo=#{object.username}"
      end

      it 'escapes values for use in JSON' do
        expect(renderer.render('foo={{object.account.display_name}}')).to eq 'foo=Foo\\"'
      end
    end
  end

  describe Webhooks::PayloadRenderer::TemplateParser do
    it 'rejects a malformed template' do
      expect { described_class.new.parse('{{') }.to raise_error(Parslet::ParseFailed)
    end
  end
end
