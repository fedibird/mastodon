# frozen_string_literal: true

class AddActionTakenAtToReports < ActiveRecord::Migration[6.1]
  def up
    add_column :reports, :action_taken_at, :datetime

    safety_assured do
      execute <<~SQL.squish
        UPDATE reports
        SET action_taken_at = updated_at
        WHERE action_taken = TRUE
      SQL
    end
  end

  def down
    safety_assured do
      execute <<~SQL.squish
        UPDATE reports
        SET action_taken = (action_taken_at IS NOT NULL)
      SQL

      remove_column :reports, :action_taken_at
    end
  end
end
