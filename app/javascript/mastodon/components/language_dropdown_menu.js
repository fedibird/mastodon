import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages } from 'react-intl';
import classNames from 'classnames';
import { supportsPassiveEvents } from 'detect-passive-events';
import { languages as preloadedLanguages } from 'mastodon/initial_state';
import Icon from 'mastodon/components/icon';

const messages = defineMessages({
  search: { id: 'compose.language.search', defaultMessage: 'Search languages...' },
  clear: { id: 'emoji_button.clear', defaultMessage: 'Clear' },
});

const listenerOptions = supportsPassiveEvents ? { passive: true, capture: true } : true;

export const languageMatches = (lang, query) => (
  [lang[0], lang[1], lang[2]].some(part => (part || '').toLocaleLowerCase().includes(query))
);

export default class LanguageDropdownMenu extends React.PureComponent {

  static propTypes = {
    value: PropTypes.string,
    frequentlyUsedLanguages: PropTypes.arrayOf(PropTypes.string).isRequired,
    pinnedLanguages: PropTypes.arrayOf(PropTypes.string),
    currentValueFirst: PropTypes.bool,
    onClose: PropTypes.func.isRequired,
    onChange: PropTypes.func.isRequired,
    languages: PropTypes.arrayOf(PropTypes.arrayOf(PropTypes.string)),
    intl: PropTypes.object,
  };

  static defaultProps = {
    languages: preloadedLanguages,
    pinnedLanguages: [],
    currentValueFirst: true,
  };

  state = {
    searchValue: '',
  };

  handleDocumentClick = e => {
    if (this.node && !this.node.contains(e.target)) {
      this.props.onClose();
      e.stopPropagation();
    }
  };

  componentDidMount () {
    document.addEventListener('click', this.handleDocumentClick, { capture: true });
    document.addEventListener('touchend', this.handleDocumentClick, listenerOptions);

    // Because of https://github.com/react-bootstrap/react-bootstrap/issues/2614 we need
    // to wait for a frame before focusing
    requestAnimationFrame(() => {
      if (this.node) {
        const element = this.node.querySelector('input[type="search"]');
        if (element) element.focus();
      }
    });
  }

  componentWillUnmount () {
    document.removeEventListener('click', this.handleDocumentClick, { capture: true });
    document.removeEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  setRef = c => {
    this.node = c;
  };

  setListRef = c => {
    this.listNode = c;
  };

  handleSearchChange = ({ target }) => {
    this.setState({ searchValue: target.value });
  };

  search () {
    const { languages, value, frequentlyUsedLanguages, pinnedLanguages, currentValueFirst } = this.props;
    const { searchValue } = this.state;
    const list = languages || [];

    // An empty query keeps the compose order unless a caller opts into pins
    // or leaves the current value in place. A query keeps search relevance.
    if (searchValue === '') {
      const rank = new Map();
      const assign = (code) => {
        if (code && !rank.has(code)) {
          rank.set(code, rank.size);
        }
      };

      pinnedLanguages.forEach(assign);

      if (currentValueFirst) {
        assign(value);
      }

      frequentlyUsedLanguages.forEach(assign);

      return [...list].sort((a, b) => {
        const rankA = rank.has(a[0]) ? rank.get(a[0]) : Infinity;
        const rankB = rank.has(b[0]) ? rank.get(b[0]) : Infinity;

        return rankA - rankB;
      });
    }

    const query = searchValue.trim().toLocaleLowerCase();

    return list.filter(lang => languageMatches(lang, query)).slice(0, 5);
  }

  handleClick = e => {
    const value = e.currentTarget.getAttribute('data-index');

    e.preventDefault();

    this.props.onChange(value);
    this.props.onClose(value);
  };

  handleKeyDown = e => {
    const { onClose } = this.props;
    const index = Array.from(this.listNode.childNodes).findIndex(node => node === e.currentTarget);

    let element = null;

    switch(e.key) {
    case 'Escape':
      onClose();
      break;
    case 'Enter':
      this.handleClick(e);
      break;
    case 'ArrowDown':
      element = this.listNode.childNodes[index + 1] || this.listNode.firstChild;
      break;
    case 'ArrowUp':
      element = this.listNode.childNodes[index - 1] || this.listNode.lastChild;
      break;
    case 'Tab':
      if (e.shiftKey) {
        element = this.listNode.childNodes[index - 1] || this.listNode.lastChild;
      } else {
        element = this.listNode.childNodes[index + 1] || this.listNode.firstChild;
      }
      break;
    case 'Home':
      element = this.listNode.firstChild;
      break;
    case 'End':
      element = this.listNode.lastChild;
      break;
    }

    if (element) {
      element.focus();
      e.preventDefault();
      e.stopPropagation();
    }
  };

  handleSearchKeyDown = e => {
    const { onChange, onClose } = this.props;
    const { searchValue } = this.state;

    let element = null;

    switch(e.key) {
    case 'Tab':
    case 'ArrowDown':
      element = this.listNode.firstChild;

      if (element) {
        element.focus();
        e.preventDefault();
        e.stopPropagation();
      }

      break;
    case 'Enter':
      element = this.listNode.firstChild;

      if (element) {
        const nextLanguage = element.getAttribute('data-index');

        onChange(nextLanguage);
        onClose(nextLanguage);
      }
      break;
    case 'Escape':
      e.preventDefault();

      if (searchValue !== '') {
        this.handleClear();
      } else {
        onClose();
      }

      break;
    }
  };

  handleClear = () => {
    this.setState({ searchValue: '' });
  };

  renderItem = lang => {
    const { value } = this.props;

    return (
      <div key={lang[0]} role='option' tabIndex={0} data-index={lang[0]} className={classNames('language-dropdown__dropdown__results__item', { active: lang[0] === value })} aria-selected={lang[0] === value} onClick={this.handleClick} onKeyDown={this.handleKeyDown}>
        <span className='language-dropdown__dropdown__results__item__native-name' lang={lang[0]}>{lang[2]}</span> <span className='language-dropdown__dropdown__results__item__common-name'>({lang[1]})</span>
      </div>
    );
  };

  render () {
    const { intl } = this.props;
    const { searchValue } = this.state;
    const isSearching = searchValue !== '';
    const results = this.search();

    return (
      <div ref={this.setRef}>
        <div className='emoji-mart-search'>
          <input type='search' value={searchValue} onChange={this.handleSearchChange} onKeyDown={this.handleSearchKeyDown} placeholder={intl.formatMessage(messages.search)} />
          <button type='button' className='emoji-mart-search-icon' disabled={!isSearching} aria-label={intl.formatMessage(messages.clear)} onClick={this.handleClear}><Icon id={isSearching ? 'times' : 'search'} /></button>
        </div>

        <div className='language-dropdown__dropdown__results emoji-mart-scroll' role='listbox' ref={this.setListRef}>
          {results.map(this.renderItem)}
        </div>
      </div>
    );
  }

}
