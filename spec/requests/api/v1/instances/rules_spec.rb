# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Rules' do
  describe 'GET /api/v1/instance/rules' do
    it 'returns hint for every rule, including an empty string, in priority then id order' do
      same_priority_lower_id = Rule.create!(text: 'First', priority: 1)
      same_priority_higher_id = Rule.create!(text: 'Second', hint: 'More detail', priority: 1)
      leading = Rule.create!(text: 'Zero', priority: 0)
      Rule.create!(text: 'Discarded', hint: 'hidden', priority: 0, deleted_at: Time.current)

      get '/api/v1/instance/rules'

      expect(response).to have_http_status(200)
      expect(response.content_type).to start_with('application/json')
      expect(body_as_json).to eq [
        { id: leading.id.to_s, text: 'Zero', hint: '' },
        { id: same_priority_lower_id.id.to_s, text: 'First', hint: '' },
        { id: same_priority_higher_id.id.to_s, text: 'Second', hint: 'More detail' },
      ]
    end
  end
end
