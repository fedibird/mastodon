# frozen_string_literal: true

class AddLocalLoadFallbackUsedToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # Shared v2 fallback fact for shadow ticks. Nullable: NULL = not
    # evaluated, false = computed without fallback, true = fallback applied.
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :local_load_fallback_used, :boolean
    end
  end
end
