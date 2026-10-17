# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FiltersController do
  render_views

  let(:user) { Fabricate(:user) }
  let(:filter) { Fabricate(:custom_filter, account: user.account) }

  before do
    sign_in(user)
    stub_webpacker_manifest
  end

  describe 'GET #edit' do
    it 'marks the title input for the reusable emoji picker' do
      get :edit, params: { id: filter }

      expect(response).to have_http_status(200)
      expect(response.body).to include('data-emoji-picker="true"')
    end

    it 'hides the individual posts section when none are attached' do
      get :edit, params: { id: filter }

      expect(response).to have_http_status(200)
      expect(response.body).not_to include(I18n.t('filters.edit.statuses'))
    end

    it 'has English and Japanese keys for the individual posts UI' do
      %w(
        filters.edit.statuses
        filters.edit.statuses_hint_html
        filters.statuses.back_to_filter
        filters.statuses.batch.remove
        filters.statuses.index.hint
        filters.statuses.index.title
        filters.index.statuses
        filters.index.statuses_long
      ).each do |key|
        expect(I18n.exists?(key, :en)).to eq(true), "missing #{key} in en"
        expect(I18n.exists?(key, :ja)).to eq(true), "missing #{key} in ja"
      end
    end

    context 'with an attached status' do
      let!(:status_filter) { Fabricate(:custom_filter_status, custom_filter: filter, status: Fabricate(:status, account: user.account)) }

      it 'shows the individual posts section and link' do
        get :edit, params: { id: filter }

        expect(response).to have_http_status(200)
        expect(response.body).to include(I18n.t('filters.edit.statuses'))
        expect(response.body).to include(filter_statuses_path(filter))
      end

      it 'renders the individual posts section in Japanese' do
        user.update!(locale: 'ja')
        get :edit, params: { id: filter }

        expect(response).to have_http_status(200)
        expect(response.body).to include('個別の投稿')
        expect(response.body).to include('フィルターを確認または投稿を削除')
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'filter form layout' do
    let(:long_keyword) { '長文のキーワード：spoilers about the season finale and more' }

    before do
      Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: long_keyword, whole_word: false)
      Fabricate(:custom_filter_keyword, custom_filter: filter, keyword: 'spoiler', whole_word: true)
    end

    [false, true].each do |embedded|
      context "with embedded=#{embedded}" do
        let(:options) { embedded ? { embedded: '1' } : {} }

        it 'stacks context choices with descriptions and keyword cards' do
          user.update!(locale: 'ja')
          get :edit, params: options.merge(id: filter)

          expect(response).to have_http_status(200)
          document = Nokogiri::HTML(response.body)
          expect(document.at_css('table.keywords-table')).to be_nil
          expect(document.at_css('fieldset.filter-contexts legend').text).to include('適用する場所')
          expect(document.at_css('.filter-contexts__hint').text).to include('複数選べます')

          items = document.css('.filter-contexts__item')
          expect(items.map { |item| item.at_css('input[type="checkbox"]')['value'] }).to eq(CustomFilter::VALID_CONTEXTS)
          items.each do |item|
            checkbox = item.at_css('input[type="checkbox"]')
            description = item.at_css('.filter-contexts__description')
            label = item.at_css('label.filter-contexts__choice')
            expect(checkbox['name']).to eq('custom_filter[context][]')
            expect(label['for']).to eq(checkbox['id'])
            expect(checkbox['aria-describedby']).to be_nil
            expect(description['id']).to eq("#{checkbox['id']}_description")
            expect(description.text).to eq(I18n.t("filters.context_descriptions.#{checkbox['value']}", locale: :ja))
            expect(item.at_css('.filter-contexts__name').text).to eq(I18n.t("filters.contexts.#{checkbox['value']}", locale: :ja))
          end
          disclosure = document.at_css('details.filter-contexts__disclosure')
          expect(disclosure['open']).to be_nil
          expect(disclosure.at_css('summary')['aria-controls']).to eq('filter-context-choices')
          expect(disclosure.at_css('summary').text).to include('各適用範囲の説明を表示')
          expect(document.at_css('#filter-context-choices .filter-contexts__item')).to be_present
          bulk = document.css('button.filter-contexts__bulk')
          expect(bulk.map { |button| button['type'] }).to eq(%w(button button))
          expect(bulk.map { |button| button['data-filter-contexts-action'] }).to eq(%w(select-all select-none))
          expect(bulk.map(&:text)).to eq(%w(すべて選択 すべて解除))
          expect(document.at_css('#custom_filter_context_public_description').text).to include('連合タイムライン', '非公開の返信')
          expect(document.at_css('#custom_filter_context_public_description').text).not_to include('ローカル')
          help = document.at_css('details.filter-keywords__help')
          expect(document.css('details.filter-keywords__help').size).to eq(1)
          expect(help['open']).to be_nil
          expect(help.at_css('summary').text).to include('単語全体にマッチとは？')
          expect(help.at_css('#filter-whole-word-help-body').text).to include('ひらがな', '#tag', 'ねこ')
          expect(help.text).not_to include('英数字のみ')
          expect(document.css('.filter-keyword__hint')).to be_empty
          expect(document.at_css('#custom_filter_context_home')['checked']).to eq('checked')
          expect(document.at_css('#custom_filter_context_notifications')['checked']).to eq('checked')
          expect(document.at_css('#custom_filter_context_public')['checked']).to be_nil
          expect(document.css('.filter-contexts__item').map { |item| item.ancestors('.filter-contexts').first }).to all(be_present)

          cards = document.css('.filter-keywords__list .filter-keyword.nested-fields')
          expect(cards.size).to eq(2)
          expect(cards.map { |card| card.at_css('input[name$="[keyword]"]')['value'] }).to contain_exactly(long_keyword, 'spoiler')
          cards.each do |card|
            keyword = card.at_css('input[name$="[keyword]"]')
            whole_word = card.at_css('input[type="checkbox"][name$="[whole_word]"]')
            expect(card.at_css('label')['for']).to eq(keyword['id'])
            expect(card.at_css('.filter-keyword__whole-word-label')['for']).to eq(whole_word['id'])
            expect(whole_word['aria-describedby']).to be_nil
            expect(card.at_css('input[name$="[id]"]')).to be_present
            expect(card.at_css('input[name$="[_destroy]"]')).to be_present
            expect(card.at_css('a.remove_fields')).to be_present
          end
          spoiler = cards.find { |card| card.at_css('input[name$="[keyword]"]')['value'] == 'spoiler' }
          phrase = cards.find { |card| card.at_css('input[name$="[keyword]"]')['value'] == long_keyword }
          expect(spoiler.at_css('input[type="checkbox"][name$="[whole_word]"]')['checked']).to eq('checked')
          expect(phrase.at_css('input[type="checkbox"][name$="[whole_word]"]')['checked']).to be_nil

          add = document.at_css('a.filter-keywords__add.add_fields')
          expect(add['data-association-insertion-node']).to eq('.filter-keywords__list')
          expect(add['data-association-insertion-method']).to eq('append')
          template = add['data-association-insertion-template']
          expect(template).to include('filter-keyword', 'nested-fields', 'whole_word')
          expect(template).not_to include('<tr')
        end
      end
    end

    it 'renders the English names and descriptions' do
      user.update!(locale: 'en')
      get :new

      document = Nokogiri::HTML(response.body)
      expect(document.css('.filter-contexts__name').map(&:text)).to eq([
        'Home and lists',
        'Notifications',
        'Public and other timelines',
        'Post threads',
        'Profile posts',
      ])
      expect(document.css('.filter-contexts__item input[type="checkbox"]').map { |input| input['checked'] }).to all(eq('checked'))
      expect(document.css('button.filter-contexts__bulk').map(&:text)).to eq(['Select all', 'Deselect all'])
      expect(document.at_css('details.filter-contexts__disclosure')['open']).to be_nil
      expect(document.at_css('#custom_filter_context_public_description').text).to include('federated timeline', 'direct messages', 'not covered by any context')
      expect(document.at_css('#custom_filter_context_public_description').text).not_to include('local timeline')
      expect(document.at_css('#filter-whole-word-help-body').text).to include('word character', '#tag')
      expect(document.at_css('#filter-whole-word-help-body').text).not_to include('alphanumeric only')
      expect(CustomFilter.new.context).to eq([])
      expect(document.at_css('#custom_filter_context_thread_description').text).to include('opened post itself', 'direct-messages column')
      expect(document.at_css('#custom_filter_context_home_description').text).to include('lists')
      checkbox = document.at_css('.filter-keyword input[type="checkbox"][name$="[whole_word]"]')
      expect(checkbox['checked']).to eq('checked')
    end

    it 'keeps keyword values and the context error when validation fails' do
      user.update!(locale: 'ja')
      post :create, params: {
        custom_filter: {
          title: 'Quiet words',
          context: [''],
          filter_action: 'warn',
          keywords_attributes: {
            '0' => { keyword: long_keyword, whole_word: '0' },
          },
        },
      }

      expect(response).to have_http_status(200)
      expect(CustomFilter.where(phrase: 'Quiet words')).to be_empty
      document = Nokogiri::HTML(response.body)
      expect(document.at_css('.filter-contexts__error').text).to include(I18n.t('filters.errors.invalid_context', locale: :ja))
      expect(document.at_css('.filter-keyword input[name$="[keyword]"]')['value']).to eq(long_keyword)
      expect(document.at_css('.filter-keyword input[type="checkbox"][name$="[whole_word]"]')['checked']).to be_nil
      expect(document.css('.filter-contexts__item input[type="checkbox"]').map { |input| input['checked'] }).to all(be_nil)
      expect(document.at_css('a.remove_fields')).to be_present
    end

    it 'keeps a partial context selection when validation fails' do
      post :create, params: {
        custom_filter: {
          title: '',
          context: ['thread', ''],
          filter_action: 'hide',
          keywords_attributes: { '0' => { keyword: 'spoiler', whole_word: '1' } },
        },
      }

      expect(response).to have_http_status(200)
      document = Nokogiri::HTML(response.body)
      checked = document.css('.filter-contexts__item input[type="checkbox"][checked]').map { |input| input['value'] }
      expect(checked).to eq(['thread'])
      expect(document.at_css('input[type="radio"][value="hide"]')['checked']).to eq('checked')
    end

    it 'saves every selected context and redisplays a partial hide selection' do
      expect do
        post :create, params: {
          custom_filter: {
            title: 'Everywhere',
            context: CustomFilter::VALID_CONTEXTS,
            filter_action: 'hide',
            keywords_attributes: { '0' => { keyword: 'spoiler', whole_word: '1' } },
          },
        }
      end.to change(CustomFilter, :count).by(1)

      created = CustomFilter.find_by!(phrase: 'Everywhere')
      expect(created.context).to eq(CustomFilter::VALID_CONTEXTS)
      expect(created).to be_hide_action

      created.update!(context: %w(public account))
      get :edit, params: { id: created }
      document = Nokogiri::HTML(response.body)
      expect(document.css('.filter-contexts__item input[type="checkbox"][checked]').map { |input| input['value'] }).to eq(%w(public account))
      expect(document.at_css('input[type="radio"][value="hide"]')['checked']).to eq('checked')
      expect(document.at_css('input[type="radio"][value="warn"]')['checked']).to be_nil
    end

    it 'uses the en_GB public label and falls back for the shared description' do
      available = I18n.available_locales
      I18n.available_locales = available + [:en_GB]

      I18n.with_locale(:en_GB) do
        expect(I18n.t('filters.contexts.public')).to eq('Public and other timelines')
        expect(I18n.t('filters.context_descriptions.public')).to include('federated timeline')
        expect(I18n.t('filters.context_descriptions.public')).not_to include('local timeline')
        expect(I18n.t('simple_form.hints.defaults.whole_word')).to include('word character')
        expect(I18n.t('simple_form.hints.defaults.whole_word')).not_to include('alphanumeric only')
        expect(I18n.t('filters.edit.select_all')).to eq('Select all')
      end
    ensure
      I18n.available_locales = available
    end

    it 'does not invent a context when none is submitted' do
      expect do
        post :create, params: {
          custom_filter: {
            title: 'Quiet words',
            filter_action: 'warn',
            keywords_attributes: { '0' => { keyword: 'spoiler', whole_word: '1' } },
          },
        }
      end.not_to change(CustomFilter, :count)

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('filters.errors.invalid_context'))
    end
  end

  describe 'GET #index' do
    it 'keeps the raw title as fallback inside a custom emoji marker' do
      filter.update!(title: 'Work :fedibird:')

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include('data-custom-emoji-text')
      expect(response.body).to include('Work :fedibird:')
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
