# frozen_string_literal: true

# Builds a valid snapshot whose stored jsonb text sits on the byte budget.
# The bulk is content_hash, which the server stores and does not recompute.
module PostDraftByteBudget
  module_function

  def under(account_id:, uuid:)
    body = template
    body['content_hash'] = 'a' * longest_hash(body, account_id, uuid)
    body
  end

  def over(account_id:, uuid:)
    body = under(account_id: account_id, uuid: uuid)
    body['content_hash'] = "#{body['content_hash']}a"
    body
  end

  def template
    {
      'schema_version' => 1,
      'media_incomplete' => false,
      'content_hash' => 'a',
      'input' => { 'text' => 'hello', 'media' => [] },
    }
  end

  def longest_hash(body, account_id, uuid)
    low = 1
    high = PostDrafts::Payload::MAX_BYTES
    best = low
    while low <= high
      mid = (low + high) / 2
      body['content_hash'] = 'a' * mid
      if fits?(body, account_id, uuid)
        best = mid
        low = mid + 1
      else
        high = mid - 1
      end
    end
    best
  end

  def fits?(body, account_id, uuid)
    normalized = PostDrafts::Payload.normalize(body, owner_account_id: account_id, client_uuid: uuid)
    limit = PostDrafts::Payload::MAX_BYTES
    PostDrafts::Payload.stored_text_bytes(body) <= limit && PostDrafts::Payload.stored_text_bytes(normalized) <= limit
  rescue PostDrafts::Payload::Invalid
    false
  end
end
