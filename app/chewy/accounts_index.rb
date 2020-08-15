# frozen_string_literal: true

class AccountsIndex < Chewy::Index
  settings index: { refresh_interval: '5m' }, analysis: {
    analyzer: {
      content: {
        tokenizer: 'whitespace',
        filter: %w(lowercase asciifolding cjk_width),
      },

      edge_ngram: {
        tokenizer: 'edge_ngram',
        filter: %w(lowercase asciifolding cjk_width),
      },

      sudachi_content: {
        filter: %w(
          lowercase
          cjk_width
          sudachi_part_of_speech
          sudachi_ja_stop
          sudachi_baseform
          search
        ),
        tokenizer: 'sudachi_tokenizer',
        type: 'custom',
      },
    },

    tokenizer: {
      edge_ngram: {
        type: 'edge_ngram',
        min_gram: 1,
        max_gram: 15,
      },
      sudachi_tokenizer: {
        type: 'sudachi_tokenizer',
        discard_punctuation: true,
        resources_path: '/etc/elasticsearch',
        settings_path: '/etc/elasticsearch/sudachi.json',
      },
    },

    filter: {
      search: {
        type: 'sudachi_split',
        mode: 'search',
      },
    },
  }

  define_type ::Account.searchable.includes(:account_stat), delete_if: ->(account) { account.destroyed? || !account.searchable? } do
    root date_detection: false do
      field :id, type: 'long'

      field :display_name, type: 'text', analyzer: 'content' do
        field :edge_ngram, type: 'text', analyzer: 'edge_ngram', search_analyzer: 'content'
      end

      field :acct, type: 'text', analyzer: 'content', value: ->(account) { [account.username, account.domain].compact.join('@') } do
        field :edge_ngram, type: 'text', analyzer: 'edge_ngram', search_analyzer: 'content'
      end

      field :actor_type, type: 'keyword', analyzer: 'content'

      field :text, type: 'text', value: ->(account) { account.index_text } do
        field :stemmed, type: 'text', analyzer: 'sudachi_content'
      end

      field :following_count, type: 'long', value: ->(account) { account.following.local.count }
      field :followers_count, type: 'long', value: ->(account) { account.followers.local.count }
      field :subscribing_count, type: 'long', value: ->(account) { account.subscribing.local.count }
      field :last_status_at, type: 'date', value: ->(account) { account.last_status_at || account.created_at }
    end
  end
end
