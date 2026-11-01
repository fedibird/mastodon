import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import RadioButton from 'mastodon/components/radio_button';

const SEARCH_LIMIT = 100;
const SEARCH_DELAY = 300;
const LANGUAGE_PATTERN = /^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8}){0,3}$/;

const messages = defineMessages({
  search: { id: 'group_directory.search', defaultMessage: 'Search groups' },
  searchPlaceholder: { id: 'group_directory.search_placeholder', defaultMessage: 'Name, @handle, or description' },
  order: { id: 'group_directory.order', defaultMessage: 'Order' },
  recentlyActive: { id: 'group_directory.recently_active', defaultMessage: 'Recently active' },
  newlyFound: { id: 'group_directory.newly_found', defaultMessage: 'Newly found' },
  scope: { id: 'group_directory.scope', defaultMessage: 'Source' },
  scopeAll: { id: 'group_directory.scope_all', defaultMessage: 'All known groups' },
  scopeLocal: { id: 'group_directory.scope_local', defaultMessage: 'On this server' },
  scopeFollowing: { id: 'group_directory.scope_following', defaultMessage: 'Following' },
  scopeFollowingDisabled: { id: 'group_directory.scope_following_disabled', defaultMessage: 'Log in to filter by groups you follow' },
  software: { id: 'group_directory.software', defaultMessage: 'Implementation' },
  softwareAll: { id: 'group_directory.software_all', defaultMessage: 'All implementations' },
  softwareOther: { id: 'group_directory.software_other', defaultMessage: 'Other' },
  softwareUnknown: { id: 'group_directory.software_unknown', defaultMessage: 'Unknown' },
  language: { id: 'group_directory.language', defaultMessage: 'Language' },
  languageAll: { id: 'group_directory.language_all', defaultMessage: 'All languages' },
  languageUnset: { id: 'group_directory.language_unset', defaultMessage: 'Not set' },
  languageTag: { id: 'group_directory.language_tag', defaultMessage: 'Specific language tag' },
  languagePlaceholder: { id: 'group_directory.language_placeholder', defaultMessage: 'ja, en-US, zh-Hans' },
  languageHint: { id: 'group_directory.language_hint', defaultMessage: 'A 2–3 letter language, then up to 3 subtags of 2–8 letters or digits, such as ja, en-US, or zh-Hans. Not every BCP 47 tag.' },
  moreFilters: { id: 'group_directory.more_filters', defaultMessage: 'More filters' },
  fewerFilters: { id: 'group_directory.fewer_filters', defaultMessage: 'Fewer filters' },
});

const SOFTWARE_OPTIONS = [
  ['', 'softwareAll'],
  ['fedibird', 'Fedibird'],
  ['lemmy', 'Lemmy'],
  ['piefed', 'PieFed'],
  ['nodebb', 'NodeBB'],
  ['mbin', 'Mbin'],
  ['mitra', 'Mitra'],
  ['other', 'softwareOther'],
  ['unknown', 'softwareUnknown'],
];

class GroupDirectoryFilterForm extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    viewKey: PropTypes.string.isRequired,
    params: PropTypes.shape({
      order: PropTypes.string,
      scope: PropTypes.string,
      software: PropTypes.string,
      q: PropTypes.string,
      language: PropTypes.string,
    }).isRequired,
    signedIn: PropTypes.bool,
    onChange: PropTypes.func.isRequired,
  };

  state = {
    query: this.props.params.q || '',
    detailsOpen: Boolean(this.props.params.software || this.props.params.language),
    languageMode: this.languageModeFrom(this.props.params.language),
    languageDraft: this.languageDraftFrom(this.props.params.language),
  };

  languageModeFrom(language) {
    if (language === 'unset') {
      return 'unset';
    }

    return language ? 'tag' : 'all';
  }

  languageDraftFrom(language) {
    if (!language || language === 'unset') {
      return '';
    }

    return language;
  }

  componentDidUpdate (prevProps) {
    if (prevProps.params.q !== this.props.params.q && this.props.params.q !== this.state.query.trim()) {
      this.setState({ query: this.props.params.q || '' });
    }

    if (prevProps.params.language === this.props.params.language) {
      return;
    }

    const incoming = this.props.params.language || '';

    // The value we just sent coming back must not reset a tag the user is still typing.
    if (this.pendingLanguage !== undefined && incoming === this.pendingLanguage) {
      this.pendingLanguage = undefined;
      return;
    }

    this.pendingLanguage = undefined;
    clearTimeout(this.languageTimer);
    this.languageTimer = null;
    const languageDraft = this.languageDraftFrom(this.props.params.language);
    const languageMode = this.languageModeFrom(this.props.params.language);

    if (languageDraft !== this.state.languageDraft || languageMode !== this.state.languageMode) {
      this.setState({ languageDraft, languageMode });
    }
  }

  componentWillUnmount () {
    clearTimeout(this.searchTimer);
    clearTimeout(this.languageTimer);
  }

  commitQuery = (query) => {
    clearTimeout(this.searchTimer);
    this.searchTimer = null;
    const next = query.trim().slice(0, SEARCH_LIMIT);
    if (next !== (this.props.params.q || '')) {
      this.props.onChange({ q: next });
    }
  };

  handleQuery = (e) => {
    const query = e.target.value.slice(0, SEARCH_LIMIT);
    this.setState({ query });
    clearTimeout(this.searchTimer);

    if (query.trim() === '') {
      this.commitQuery('');
      return;
    }

    this.searchTimer = setTimeout(() => this.commitQuery(query), SEARCH_DELAY);
  };

  handleQueryKeyDown = (e) => {
    if (e.key !== 'Enter') {
      return;
    }

    e.preventDefault();
    this.commitQuery(this.state.query);
  };

  handleOrder = (e) => {
    this.props.onChange({ order: e.target.value });
  };

  handleScope = (e) => {
    this.props.onChange({ scope: e.target.value });
  };

  handleSoftware = (e) => {
    this.props.onChange({ software: e.target.value });
  };

  commitLanguage = (language) => {
    const current = this.props.params.language || '';

    if (current === language) {
      return;
    }

    this.pendingLanguage = language;
    this.props.onChange({ language });
  };

  handleLanguageMode = (e) => {
    const languageMode = e.target.value;
    clearTimeout(this.languageTimer);
    this.languageTimer = null;

    if (languageMode === 'all') {
      this.setState({ languageMode: 'all', languageDraft: '' });
      this.commitLanguage('');
      return;
    }

    if (languageMode === 'unset') {
      this.setState({ languageMode: 'unset', languageDraft: '' });
      this.commitLanguage('unset');
      return;
    }

    const draft = this.state.languageDraft.trim();
    this.setState({ languageMode: 'tag' });

    if (LANGUAGE_PATTERN.test(draft)) {
      this.commitLanguage(draft);
      return;
    }

    // Empty or unfinished input is not a tag. Drop unset and any previous tag
    // so the list matches the screen, and do not query with the partial text.
    this.commitLanguage('');
  };

  handleLanguageDraft = (e) => {
    const languageDraft = e.target.value.slice(0, 35);
    this.setState({ languageDraft, languageMode: 'tag' });
    clearTimeout(this.languageTimer);
    this.languageTimer = null;

    const trimmed = languageDraft.trim();

    if (trimmed === '') {
      this.commitLanguage('');
      return;
    }

    if (!LANGUAGE_PATTERN.test(trimmed)) {
      return;
    }

    this.languageTimer = setTimeout(() => {
      this.languageTimer = null;
      this.commitLanguage(trimmed);
    }, SEARCH_DELAY);
  };

  toggleDetails = () => {
    this.setState(state => ({ detailsOpen: !state.detailsOpen }));
  };

  softwareLabel = (key) => {
    if (messages[key]) {
      return this.props.intl.formatMessage(messages[key]);
    }

    return key;
  };

  render () {
    const { intl, viewKey, params, signedIn } = this.props;
    const { query, detailsOpen, languageMode, languageDraft } = this.state;
    const languageInvalid = languageMode === 'tag' && languageDraft.trim() !== '' && !LANGUAGE_PATTERN.test(languageDraft.trim());
    const detailsId = `group-directory-details-${viewKey}`;

    return (
      <div className='filter-form group-directory-filters'>
        <label className='group-directory-filters__field'>
          <span className='group-directory-filters__label'>{intl.formatMessage(messages.search)}</span>
          <input
            type='search'
            className='group-directory-filters__search'
            value={query}
            onChange={this.handleQuery}
            onKeyDown={this.handleQueryKeyDown}
            maxLength={SEARCH_LIMIT}
            placeholder={intl.formatMessage(messages.searchPlaceholder)}
            autoComplete='off'
          />
        </label>

        <div className='group-directory-filters__row' role='group' aria-label={intl.formatMessage(messages.order)}>
          <RadioButton name={`group-directory-order-${viewKey}`} value='active' label={intl.formatMessage(messages.recentlyActive)} checked={params.order !== 'new'} onChange={this.handleOrder} />
          <RadioButton name={`group-directory-order-${viewKey}`} value='new' label={intl.formatMessage(messages.newlyFound)} checked={params.order === 'new'} onChange={this.handleOrder} />
        </div>

        <div className='group-directory-filters__row' role='group' aria-label={intl.formatMessage(messages.scope)}>
          <RadioButton name={`group-directory-scope-${viewKey}`} value='all' label={intl.formatMessage(messages.scopeAll)} checked={params.scope !== 'local' && params.scope !== 'following'} onChange={this.handleScope} />
          <RadioButton name={`group-directory-scope-${viewKey}`} value='local' label={intl.formatMessage(messages.scopeLocal)} checked={params.scope === 'local'} onChange={this.handleScope} />
          <RadioButton name={`group-directory-scope-${viewKey}`} value='following' label={intl.formatMessage(messages.scopeFollowing)} checked={params.scope === 'following'} disabled={!signedIn} title={signedIn ? undefined : intl.formatMessage(messages.scopeFollowingDisabled)} onChange={this.handleScope} />
        </div>

        <button
          type='button'
          className='group-directory-filters__details'
          aria-expanded={detailsOpen}
          aria-controls={detailsId}
          onClick={this.toggleDetails}
        >
          {intl.formatMessage(detailsOpen ? messages.fewerFilters : messages.moreFilters)}
        </button>

        {detailsOpen && (
          <div id={detailsId}>
            <label className='group-directory-filters__field'>
              <span className='group-directory-filters__label'>{intl.formatMessage(messages.software)}</span>
              {/* The choice should apply when it is made, including by keyboard. */}
              {/* eslint-disable-next-line jsx-a11y/no-onchange */}
              <select className='group-directory-filters__select' value={params.software || ''} onChange={this.handleSoftware}>
                {SOFTWARE_OPTIONS.map(([value, label]) => (
                  <option value={value} key={value || 'all'}>{this.softwareLabel(label)}</option>
                ))}
              </select>
            </label>

            <label className='group-directory-filters__field'>
              <span className='group-directory-filters__label'>{intl.formatMessage(messages.language)}</span>
              {/* eslint-disable-next-line jsx-a11y/no-onchange */}
              <select className='group-directory-filters__select' value={languageMode} onChange={this.handleLanguageMode}>
                <option value='all'>{intl.formatMessage(messages.languageAll)}</option>
                <option value='unset'>{intl.formatMessage(messages.languageUnset)}</option>
                <option value='tag'>{intl.formatMessage(messages.languageTag)}</option>
              </select>
            </label>

            {languageMode === 'tag' && (
              <div className='group-directory-filters__field'>
                <label className='group-directory-filters__label' htmlFor={`group-directory-language-${viewKey}`}>
                  {intl.formatMessage(messages.languageTag)}
                </label>
                <input
                  id={`group-directory-language-${viewKey}`}
                  type='text'
                  className='group-directory-filters__search'
                  value={languageDraft}
                  onChange={this.handleLanguageDraft}
                  maxLength={35}
                  placeholder={intl.formatMessage(messages.languagePlaceholder)}
                  aria-invalid={languageInvalid}
                  aria-describedby={`group-directory-language-hint-${viewKey}`}
                  autoComplete='off'
                  spellCheck='false'
                />
                <p id={`group-directory-language-hint-${viewKey}`} className='group-directory-filters__hint'>
                  {intl.formatMessage(messages.languageHint)}
                </p>
              </div>
            )}
          </div>
        )}
      </div>
    );
  }

}

export default injectIntl(GroupDirectoryFilterForm);
