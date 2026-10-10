# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261009170000_detach_posting_identity_post_status_fkey.rb')
require Rails.root.join('db/migrate/20261009171000_validate_posting_identity_post_foreign_keys.rb')

RSpec.describe DetachPostingIdentityPostStatusFkey do
  def status_foreign_key?
    ActiveRecord::Base.connection.foreign_key_exists?(:posting_identity_posts, :statuses)
  end

  def parent_foreign_keys
    ActiveRecord::Base.connection.foreign_keys(:posting_identity_posts).reject { |key| key.to_table == 'statuses' }
  end

  it 'keeps status_id unconstrained and cascades the parent keys' do
    expect(status_foreign_key?).to be false

    keys = parent_foreign_keys

    expect(keys.map(&:to_table)).to contain_exactly('users', 'accounts', 'posting_identity_delegations')
    expect(keys.map(&:on_delete).uniq).to eq([:cascade])
    expect(keys).to all(be_validated)
  end

  it 'removes a status foreign key left by an older install and refuses to restore it' do
    connection = ActiveRecord::Base.connection
    connection.add_foreign_key :posting_identity_posts, :statuses, column: :status_id, validate: false unless status_foreign_key?

    migration = described_class.new
    migration.version = 20_261_009_170_000

    expect { migration.up }.not_to raise_error
    expect(status_foreign_key?).to be false
    expect(parent_foreign_keys.map(&:on_delete).uniq).to eq([:cascade])

    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /status_id/)
    expect(status_foreign_key?).to be false
  end

  it 'accepts the non-validating foreign key and the later validation' do
    migration = described_class.new
    migration.version = 20_261_009_170_000
    checker = StrongMigrations::Checker.new(migration)

    expect do
      checker.perform(:add_foreign_key, :posting_identity_posts, :accounts, { column: :posting_account_id, on_delete: :cascade, validate: false }) {}
    end.not_to raise_error

    expect do
      checker.perform(:add_foreign_key, :posting_identity_posts, :statuses, { column: :status_id }) {}
    end.to raise_error(StrongMigrations::UnsafeMigration)

    validator = ValidatePostingIdentityPostForeignKeys.new
    validator.version = 20_261_009_171_000
    validation = StrongMigrations::Checker.new(validator)

    expect do
      validation.perform(:validate_foreign_key, :posting_identity_posts, :users) {}
    end.not_to raise_error
  end
end
