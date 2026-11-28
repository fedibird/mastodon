# frozen_string_literal: true

# Substring checks for GroupDirectoryIndex.
#
# `text.infix` is a 2..20 character ngram over one combined field. A query
# longer than 20 characters is sent as overlapping 20-character windows so
# Elasticsearch can reject documents that are missing a piece. Those windows
# are not a contiguous match: the pieces can sit in different places, or on
# different sides of the newline that joins the name and the note.
#
# ElasticsearchQuery ANDs the windows. CandidatePage then calls contiguous?
# on the current account and keeps the hit only when the whole query sits
# inside one of the fields the SQL ILIKE expression searches. That check is
# bounded to the candidate ids. It is not a table-wide ILIKE.
#
# fold approximates the infix analyzer (lowercase, ASCII folding, CJK width).
# PostgreSQL ILIKE does not fold width or accents the same way, and the
# indexed note is the tag-stripped prefix. Those differences are documented
# in docs/group_directory_es_search.md. The search flag stays off until they
# are accepted.
class GroupDirectory::SearchText
  WINDOW_STEP = 10

  class << self
    def fold(text)
      text.to_s.unicode_normalize(:nfkc).unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase
    end

    # Raw slices. The search analyzer folds each slice. A single slice is the
    # whole query when it already fits in one gram.
    def windows(query)
      text = query.to_s
      limit = GroupDirectoryIndex::INFIX_MAX_GRAM
      return [text] if text.length <= limit

      starts = (0..text.length - limit).step(WINDOW_STEP).to_a
      tail = text.length - limit
      starts << tail unless starts.last == tail
      starts.map { |start| text[start, limit] }
    end

    def contiguous?(account, query)
      needle = fold(query)
      return false if needle.empty?

      fields(account).any? { |field| fold(field).include?(needle) }
    end

    def fields(account)
      username = account.username.to_s
      domain = account.domain
      handle = domain.present? ? "#{username}@#{domain}" : username
      [account.display_name, username, domain, account.note, handle]
    end
  end
end
