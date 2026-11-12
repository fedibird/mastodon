# frozen_string_literal: true

# Directory search document for listable groups.
#
# GroupDirectory::Listing reads this index only when GROUP_DIRECTORY_ES_SEARCH
# is true. That flag defaults off, and it is separate from live sync.
# GROUP_DIRECTORY_INDEX=true fills and updates the index. A full
# `tootctl search deploy` does not create or rebuild this index. The API
# keeps using GroupDirectory::Query until the search flag is turned on.
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
# longer than 20 characters has no single gram. ElasticsearchQuery ANDs
# overlapping 20-character windows, then SearchText requires the whole
# query inside one current field. Windows alone can match separate pieces.
# One-character substrings are not grams, matching the two-character rule.
#
# A 2500-character text field produces at most 47_310 ngram windows, and a
# 2000-character note produces at most 37_810. Do not set
# GROUP_DIRECTORY_INDEX in production until index size, bulk throughput,
# and search latency have been measured on the real cluster. With the
# search flag off, SQL still searches the full note. With the flag on, a
# match past the indexed prefix is absent. Do not turn the flag on until
# that difference is accepted. See docs/group_directory_es_search.md.
#
# `last_status_at` stays null when the column is null. It is not replaced
# with created_at. Elasticsearch treats a null date as a missing value, so
# sort it with missing: _last, then id desc, to match NULLS LAST plus the
# id tie-break. order=new is this id, not created_at.
#
# Rollout:
#   1. Deploy this code with GROUP_DIRECTORY_INDEX unset.
#   2. bin/tootctl search deploy --only group_directory
#      This add-only pass can leave a document for a group that becomes
#      unlisted while the flag is still off. Nothing is enqueueing then.
#   3. Set GROUP_DIRECTORY_INDEX=true and restart web and Sidekiq so later
#      changes are captured.
#   4. Before treating the index as caught up, run
#      bin/tootctl search deploy --only group_directory --rebuild
#      Rebuild purges this index and refills the groups that are eligible
#      now. A second plain deploy does not delete the step-2 leftovers.
# index.gc_deletes is 1h. The 300s inflight lease does not stop a worker
# by itself. The writer checks the claim again immediately before the bulk
# request. That check and the request are not atomic: a process that pauses
# inside the request, past gc_deletes, can still resurrect a deleted
# document. Recovery is --rebuild. Confirm a delayed resume on a real
# cluster before the flag is turned on. A 409 is harmless only when Redis
# has a newer version, or the stored document is already the one we meant
# to write. An equal version with a different document, including a delete
# that leaves the public document in place, is a version gap.
# Rollback of live sync: unset GROUP_DIRECTORY_INDEX and restart.
# Rollback of search: unset GROUP_DIRECTORY_ES_SEARCH and restart web.
# Search then uses SQL again. Leave the index in place.
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

  settings index: {
    refresh_interval: '30s',
    max_ngram_diff: INFIX_MAX_GRAM - INFIX_MIN_GRAM,
    gc_deletes: '1h',
  }, analysis: {
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
