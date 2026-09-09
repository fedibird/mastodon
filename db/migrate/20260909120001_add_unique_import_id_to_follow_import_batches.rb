# frozen_string_literal: true

class AddUniqueImportIdToFollowImportBatches < ActiveRecord::Migration[6.1]
  def change
    safety_assured do
      add_index :follow_import_batches, :import_id,
                unique: true,
                where: 'import_id IS NOT NULL',
                name: :index_follow_import_batches_on_import_id
    end
  end
end
