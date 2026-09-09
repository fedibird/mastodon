# frozen_string_literal: true

class AddSourceEventKeyToModerationEvents < ActiveRecord::Migration[6.1]
  def change
    add_column :moderation_interaction_events, :source_event_key, :string
    add_column :moderation_rejection_events, :source_event_key, :string

    safety_assured do
      add_index :moderation_interaction_events, :source_event_key,
                unique: true,
                where: 'source_event_key IS NOT NULL',
                name: :index_mod_interaction_events_on_source_event_key
      add_index :moderation_rejection_events, :source_event_key,
                unique: true,
                where: 'source_event_key IS NOT NULL',
                name: :index_mod_rejection_events_on_source_event_key
    end
  end
end
