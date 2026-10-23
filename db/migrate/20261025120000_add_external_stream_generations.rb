# frozen_string_literal: true

# Two nullable-or-default columns on the projection marker. They record which
# content generation was committed and which one was successfully published.
# They do not copy status text. PostgreSQL 11+ adds a constant default without
# rewriting the table. statuses is not changed.
class AddExternalStreamGenerations < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      add_column :external_status_projections, :content_generation, :bigint, null: false, default: 0
      add_column :external_status_projections, :streamed_content_generation, :bigint
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout = '5s'"
      remove_column :external_status_projections, :streamed_content_generation
      remove_column :external_status_projections, :content_generation
    end
  end
end
