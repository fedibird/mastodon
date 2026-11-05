# frozen_string_literal: true

# In-memory stand-in for GroupDirectoryIndex.
#
# It applies the bool filter this repository builds, sorts like the
# directory (missing last_status_at last, then id), and honors
# search_after. It is not a real cluster. Request specs that use it say so.
class GroupDirectoryEsIndex
  attr_reader :requests, :closed, :closed_id, :issued_pit_ids
  attr_accessor :after_first_search

  def initialize(overrides: [])
    @overrides = overrides
    @requests = []
    @closed = 0
    @issued_pit_ids = []
  end

  def open_point_in_time(*)
    @pit_id = "pit-#{object_id}-#{@closed}"
    @snapshot = documents.map(&:dup)
    @search_count = 0
    { 'id' => @pit_id }
  end

  def close_point_in_time(arguments = nil)
    body = arguments.is_a?(Hash) ? (arguments[:body] || arguments['body']) : nil
    @closed_id = body[:id] || body['id'] if body.is_a?(Hash)
    @closed += 1
    @pit_id = nil
    { 'succeeded' => true }
  end

  def search(request)
    body = symbolize(request[:body] || request['body'] || {})
    assert_safe_query!(body)
    raise 'search without a point in time' if body.dig(:pit, :id) != @pit_id

    if @after_first_search && @search_count.to_i.positive?
      @after_first_search.call
      @after_first_search = nil
    end
    @search_count = @search_count.to_i + 1
    specs = sort_specs(body[:sort])
    matched = @snapshot.select { |doc| filters_match?(doc, body.dig(:query, :bool, :filter)) }
    ordered = matched.sort_by { |doc| sort_rank(doc, specs) }
    cursor = body[:search_after]
    if cursor
      cursor_rank = rank_of(cursor, specs)
      ordered = ordered.drop_while { |doc| (sort_rank(doc, specs) <=> cursor_rank) <= 0 }
    end
    hits = ordered.first(body[:size].to_i).map do |doc|
      { '_id' => doc.fetch('id').to_s, 'sort' => sort_key(doc, specs) }
    end
    @pit_id = "#{body.dig(:pit, :id)}-r#{@search_count}"
    @issued_pit_ids << @pit_id
    { 'pit_id' => @pit_id, 'hits' => { 'hits' => hits } }
  end

  private

  def documents
    by_id = {}
    GroupDirectory::Eligibility.scope.find_each do |account|
      by_id[account.id] = document_for(account)
    end
    @overrides.each do |account|
      by_id[account.id] = document_for(account)
    end
    by_id.values
  end

  def document_for(account)
    raw = GroupDirectoryIndex.compose(account)
    raw.each_with_object({}) do |(key, value), memo|
      memo[key.to_s] = value
    end.tap { |doc| doc['id'] ||= account.id }
  end

  def assert_safe_query!(body)
    dumped = body.to_s
    raise 'query_string is not allowed' if dumped.include?('query_string')
    raise 'wildcard is not allowed' if dumped.include?('wildcard')
    raise 'regexp is not allowed' if dumped.include?('regexp')
  end

  def filters_match?(doc, filters)
    Array(filters).all? { |clause| clause_match?(doc, clause) }
  end

  def clause_match?(doc, clause)
    clause = symbolize(clause)
    if clause.key?(:term)
      term_match?(doc, clause[:term])
    elsif clause.key?(:terms)
      terms_match?(doc, clause[:terms])
    elsif clause.key?(:match)
      infix_match?(doc, clause[:match])
    elsif clause.key?(:bool)
      bool_match?(doc, clause[:bool])
    else
      raise "unsupported directory clause #{clause.keys.inspect}"
    end
  end

  def bool_match?(doc, bool)
    Array(bool[:filter]).all? { |clause| clause_match?(doc, clause) } &&
      Array(bool[:must_not]).none? { |clause| clause_match?(doc, clause) }
  end

  def terms_match?(doc, terms)
    field, expected = terms.first
    Array(expected).map(&:to_s).include?(doc[field.to_s].to_s)
  end

  def term_match?(doc, term)
    field, expected = term.first
    actual = doc[field.to_s]
    if actual.is_a?(Array)
      actual.map(&:to_s).include?(expected.to_s)
    elsif actual == true || actual == false
      actual == expected
    else
      actual.to_s == expected.to_s
    end
  end

  def infix_match?(doc, match)
    field, body = match.first
    return false unless field.to_s == 'text.infix'

    token = body[:query].to_s
    return false unless token.length.between?(GroupDirectoryIndex::INFIX_MIN_GRAM, GroupDirectoryIndex::INFIX_MAX_GRAM)

    GroupDirectory::SearchText.fold(doc['text']).include?(GroupDirectory::SearchText.fold(token))
  end

  def sort_specs(sorts)
    Array(sorts).map do |entry|
      field, options = entry.first
      options = { order: options } unless options.is_a?(Hash)
      { field: field.to_s, order: options[:order].to_s }
    end
  end

  def sort_key(doc, specs)
    specs.map { |spec| sort_value(doc, spec[:field]) }
  end

  def sort_rank(doc, specs)
    rank_of(sort_key(doc, specs), specs)
  end

  def rank_of(key, specs)
    key.zip(specs).flat_map { |value, spec| rank_parts(value, spec[:order]) }
  end

  # missing values sort last for both directions. A descending value then
  # uses a negated number so a plain ascending compare matches Elasticsearch.
  def rank_parts(value, order)
    missing = value.nil? ? 1 : 0
    number = value.nil? ? 0 : value
    [missing, order == 'desc' ? -number : number]
  end

  def sort_value(doc, field)
    raw = doc[field]
    case field
    when 'last_status_at'
      raw.nil? ? nil : (raw.to_time.to_f * 1000).to_i
    when 'id'
      raw.to_i
    else
      raw
    end
  end

  def symbolize(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child), memo| memo[key.to_sym] = symbolize(child) }
    when Array
      value.map { |child| symbolize(child) }
    else
      value
    end
  end
end
