# frozen_string_literal: true

class AddIndexIpBlocksOnIp < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    deduplicate_ip_blocks!
    add_index :ip_blocks, :ip, unique: true, algorithm: :concurrently, name: :index_ip_blocks_on_ip
  end

  def down
    remove_index :ip_blocks, name: :index_ip_blocks_on_ip, algorithm: :concurrently
  end

  private

  # Keep one row per exact PostgreSQL inet value. Different CIDR prefixes
  # are distinct inet values and must not be collapsed together.
  def deduplicate_ip_blocks!
    duplicates = select_all(<<~SQL.squish)
      SELECT string_agg(id::text, ',' ORDER BY id) AS ids
      FROM ip_blocks
      GROUP BY ip
      HAVING count(*) > 1
    SQL

    duplicates.each do |row|
      ids = row['ids'].split(',')
      next if ids.size < 2

      # Exact inet duplicates only; keep the newest id. Different CIDR prefixes are distinct.
      safety_assured { execute("DELETE FROM ip_blocks WHERE id IN (#{ids[0...-1].map(&:to_i).join(',')})") }
    end
  end
end
