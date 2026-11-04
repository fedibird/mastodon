# frozen_string_literal: true

# Directory search document for listable groups.
#
# The directory API still uses GroupDirectory::Query. This index is filled
# only when an operator asks for it, and live sync stays off until
# GROUP_DIRECTORY_INDEX=true. A full `tootctl search deploy` does not create
# or rebuild this index.
#
# Plugins match AccountsIndex: analysis-sudachi, analysis-nori,
# analysis-ik, and the stconvert character filter. Creating the index fails
# closed if those plugins are missing.
#
# Substring search is a bounded ngram (min 2, max 20) on `text`, which holds
# the name, handle, domain, and tag-stripped description. Edge ngram is not
# used: a prefix gram does not match the middle of a name. The search
# analyzer is a single lowercased token, so "%" and "_" stay literal
# characters and the query is not a query_string or a wildcard. A query
# longer than 20 characters has no single gram; the later query builder has
# to AND overlapping 20-character windows. One-character substrings are not
# grams, matching the current two-character rule.
#
# A 2500-character text field produces at most 47_310 ngram windows, and a
# 2000-character note produces at most 37_810. Do not set
# GROUP_DIRECTORY_INDEX in production until index size, bulk throughput,
# and search latency have been measured on the real cluster. The directory
# API still searches the full note with SQL.
#
# `last_status_at` stays null when the column is null. It is not replaced
# with created_at. Elasticsearch treats a null date as a missing value, so
# sort it with missing: _last, then id desc, to match NULLS LAST plus the
# id tie-break. order=new is this id, not created_at.
#
# Rollout:
#   1. Deploy this code with GROUP_DIRECTORY_INDEX unset.
#   2. bin/tootctl search deploy --only group_directory
#   3. Set GROUP_DIRECTORY_INDEX=true and restart web and Sidekiq.
#   4. Run the same deploy once more so rows that changed during the first
#      import are included.
# Rollback: unset GROUP_DIRECTORY_INDEX and restart. The API is still SQL.
# Optional: GroupDirectoryIndex.purge in a console. Do not purge the
# accounts, tags, or statuses indexes. Redis keys
# group_directory:index:pending and group_directory:index:scheduled can be
# deleted. A mapping change purges only this index, because deploy calls
# purge when this index's specification changed.
class GroupDirectoryIndex < Chewy::Index
  INFIX_MIN_GRAM = 2
  INFIX_MAX_GRAM = 20

  def self.infix_window_upper_bound(length)
    return 0 if length < INFIX_MIN_GRAM

    max_gram = [INFIX_MAX_GRAM, length].min
    (INFIX_MIN_GRAM..max_gram).sum { |gram| length - gram + 1 }
  end

  settings index: { refresh_interval: '30s', max_ngram_diff: INFIX_MAX_GRAM - INFIX_MIN_GRAM }, analysis: {
    filter: {
      english_stop: {
        type: 'stop',
        stopwords: '_english_',
      },
      english_stemmer: {
        type: 'stemmer',
        language: 'english',
      },
      english_possessive_stemmer: {
        type: 'stemmer',
        language: 'possessive_english',
      },
      search: {
        type: 'sudachi_split',
        mode: 'search',
      },
    },
    char_filter: {
      tsconvert: {
        type: 'stconvert',
        keep_both: false,
        delimiter: '#',
        convert_type: 't2s',
      },
    },
    tokenizer: {
      infix_ngram: {
        type: 'ngram',
        min_gram: INFIX_MIN_GRAM,
        max_gram: INFIX_MAX_GRAM,
      },
      sudachi_tokenizer: {
        type: 'sudachi_tokenizer',
        discard_punctuation: true,
        resources_path: '/etc/elasticsearch/sudachi',
        settings_path: '/etc/elasticsearch/sudachi/sudachi.json',
      },
      nori_user_dict: {
        type: 'nori_tokenizer',
        decompound_mode: 'mixed',
      },
    },
    analyzer: {
      verbatim: {
        tokenizer: 'whitespace',
        filter: %w(lowercase asciifolding cjk_width),
      },
      infix: {
        tokenizer: 'infix_ngram',
        filter: %w(lowercase asciifolding cjk_width),
      },
      infix_query: {
        tokenizer: 'keyword',
        filter: %w(lowercase asciifolding cjk_width),
      },
      content: {
        tokenizer: 'uax_url_email',
        filter: %w(
          english_possessive_stemmer
          lowercase
          asciifolding
          cjk_width
          english_stop
          english_stemmer
        ),
      },
      ja_text: {
        tokenizer: 'sudachi_tokenizer',
        type: 'custom',
        filter: %w(
          lowercase
          asciifolding
          cjk_width
          sudachi_part_of_speech
          sudachi_ja_stop
          sudachi_baseform
          search
        ),
      },
      ko_text: {
        tokenizer: 'nori_user_dict',
        filter: %w(lowercase asciifolding cjk_width),
      },
      zh_text: {
        tokenizer: 'ik_max_word',
        filter: %w(lowercase asciifolding cjk_width),
        char_filter: %w(tsconvert),
      },
    },
  }

  index_scope GroupDirectory::Eligibility.scope,
              delete_if: ->(account) { !GroupDirectory::Eligibility.eligible?(account) }

  root date_detection: false do
    field :id, type: 'long'
    field :display_name, type: 'text', analyzer: 'verbatim', value: ->(account) { account.display_name.to_s } do
      field :ja, type: 'text', analyzer: 'ja_text'
      field :ko, type: 'text', analyzer: 'ko_text'
      field :zh, type: 'text', analyzer: 'zh_text'
    end
    field :username, type: 'keyword', value: ->(account) { GroupDirectory::Document.username(account) }
    field :acct, type: 'keyword', value: ->(account) { GroupDirectory::Document.acct(account) }
    field :local_domain_acct, type: 'keyword', value: ->(account) { GroupDirectory::Document.local_domain_acct(account) }
    field :domain, type: 'keyword', value: ->(account) { GroupDirectory::Document.domain_key(account) }
    field :note, type: 'text', analyzer: 'verbatim', value: ->(account) { GroupDirectory::Document.plain_note(account) } do
      field :ja, type: 'text', analyzer: 'ja_text'
      field :ko, type: 'text', analyzer: 'ko_text'
      field :zh, type: 'text', analyzer: 'zh_text'
    end
    field :text, type: 'text', analyzer: 'verbatim', value: ->(account) { GroupDirectory::Document.search_text(account) } do
      field :infix, type: 'text', analyzer: 'infix', search_analyzer: 'infix_query'
      field :en, type: 'text', analyzer: 'content'
      field :ja, type: 'text', analyzer: 'ja_text'
      field :ko, type: 'text', analyzer: 'ko_text'
      field :zh, type: 'text', analyzer: 'zh_text'
    end
    field :actor_type, type: 'keyword'
    field :listed, type: 'boolean', value: ->(account) { GroupDirectory::Eligibility.eligible?(account) }
    field :local, type: 'boolean', value: ->(account) { account.local? }
    field :software_name, type: 'keyword', value: ->(account) { GroupDirectory::Document.software_name(account) }
    field :software_bucket, type: 'keyword', value: ->(account) { GroupDirectory::Document.software_bucket(account) }
    field :languages, type: 'keyword', value: ->(account) { GroupDirectory::Document.language_tags(account) }
    field :languages_unset, type: 'boolean', value: ->(account) { GroupDirectory::Document.language_tags(account).empty? }
    field :last_status_at, type: 'date', value: ->(account) { GroupDirectory::Document.last_status_at(account) }
  end
end
