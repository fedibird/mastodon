# frozen_string_literal: true

module PostDrafts
  module StyleFields
    STYLE_KEYS = %w(
      selected_id applied_revision usage_mode selection_kind selection_origin
      manual_fields manual_values suppressions style_owned_fields unapplied
      destination_source destination_policy destination_account_id destination_status snapshot
    ).freeze

    private

    def style(value)
      return nil if value.nil?

      require_object!(value, 'input.user_posting_style')
      reject_unknown!(value, STYLE_KEYS, 'input.user_posting_style')
      style_identity(value).merge(style_lists(value)).merge(style_destination(value))
    end

    def style_identity(value)
      {
        'selected_id' => reference(value['selected_id'], 'input.user_posting_style.selected_id'),
        'applied_revision' => small_integer(value['applied_revision'], 'input.user_posting_style.applied_revision'),
        'usage_mode' => token(value['usage_mode'], 'input.user_posting_style.usage_mode') || 'usual',
        'selection_kind' => token(value['selection_kind'], 'input.user_posting_style.selection_kind') || 'pending',
        'selection_origin' => token(value['selection_origin'], 'input.user_posting_style.selection_origin'),
      }
    end

    def style_lists(value)
      {
        'manual_fields' => string_list(value['manual_fields'], 'input.user_posting_style.manual_fields'),
        'manual_values' => scalar_hash(value['manual_values'], 'input.user_posting_style.manual_values'),
        'suppressions' => string_list(value['suppressions'], 'input.user_posting_style.suppressions'),
        'style_owned_fields' => string_list(value['style_owned_fields'], 'input.user_posting_style.style_owned_fields'),
        'unapplied' => string_list(value['unapplied'], 'input.user_posting_style.unapplied'),
        'snapshot' => style_snapshot(value['snapshot']),
      }
    end

    def style_destination(value)
      {
        'destination_source' => token(value['destination_source'], 'input.user_posting_style.destination_source'),
        'destination_policy' => token(value['destination_policy'], 'input.user_posting_style.destination_policy'),
        'destination_account_id' => reference(value['destination_account_id'], 'input.user_posting_style.destination_account_id'),
        'destination_status' => token(value['destination_status'], 'input.user_posting_style.destination_status') || 'idle',
      }
    end

    def style_snapshot(value)
      return nil if value.nil?

      require_object!(value, 'input.user_posting_style.snapshot')
      reject_unknown!(value, %w(id name revision target defaults managed), 'input.user_posting_style.snapshot')
      {
        'id' => reference(value['id'], 'input.user_posting_style.snapshot.id'),
        'name' => bounded_string(value['name'], 'input.user_posting_style.snapshot.name', 200, default: ''),
        'revision' => small_integer(value['revision'], 'input.user_posting_style.snapshot.revision'),
        'target' => scalar_hash(value['target'], 'input.user_posting_style.snapshot.target'),
        'defaults' => scalar_hash(value['defaults'], 'input.user_posting_style.snapshot.defaults'),
        'managed' => managed(value['managed']),
      }
    end

    def scalar_hash(value, key)
      return {} if value.nil?

      require_object!(value, key)
      fail!('too_many', key) if value.size > Payload::LIST_MAX
      value.map { |child, item| scalar_entry(child, item, key) }.to_h
    end

    def scalar_entry(child, item, key)
      name = child.to_s
      fail!('invalid_format', key) unless name.match?(/\A[A-Za-z0-9_:-]{1,64}\z/)

      [name, record_value(item, "#{key}.#{name}")]
    end
  end
end
