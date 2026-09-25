import PropTypes from 'prop-types';
import React, { PureComponent } from 'react';

import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';

import { connect } from 'react-redux';

import classNames from 'classnames';
import ImmutablePropTypes from 'react-immutable-proptypes';

import Icon from 'mastodon/components/icon';
import CustomEmojiText from 'mastodon/components/custom_emoji_text';
import { toServerSideType } from 'mastodon/utils/filters';

const messages = defineMessages({
  search: { id: 'filter_modal.select_filter.search', defaultMessage: 'Search or create' },
  clear: { id: 'emoji_button.clear', defaultMessage: 'Clear' },
});

const mapStateToProps = (state, { contextType }) => ({
  customEmojis: state.get('custom_emojis'),
  filters: Array.from(state.get('filters').values()).map((filter) => [
    filter.get('id'),
    filter.get('title'),
    filter.get('keywords')?.map(keyword => keyword.get('keyword')).join('\n') || '',
    Boolean(filter.get('expires_at') && filter.get('expires_at') < Date.now()),
    Boolean(contextType && filter.get('context') && !filter.get('context').includes(toServerSideType(contextType))),
  ]),
});

class SelectFilter extends PureComponent {

  static propTypes = {
    onSelectFilter: PropTypes.func.isRequired,
    onNewFilter: PropTypes.func.isRequired,
    filters: PropTypes.array,
    customEmojis: ImmutablePropTypes.list.isRequired,
    intl: PropTypes.object.isRequired,
  };

  state = {
    searchValue: '',
  };

  search () {
    const { filters } = this.props;
    const { searchValue } = this.state;
    const query = searchValue.trim().toLowerCase();

    if (query === '') {
      return filters;
    }

    return filters.filter(filter => (
      (filter[1] || '').toLowerCase().includes(query)
      || (filter[2] || '').toLowerCase().includes(query)
    ));
  }

  renderItem = filter => {
    let warning = null;

    if (filter[3] || filter[4]) {
      warning = (
        <span className='filter-modal__warning'>
          {' '}
          (
          {filter[3] && (
            <FormattedMessage id='filter_modal.select_filter.expired' defaultMessage='Expired' />
          )}
          {filter[3] && filter[4] && ', '}
          {filter[4] && (
            <FormattedMessage id='filter_modal.select_filter.context_mismatch' defaultMessage='Does not apply to this context' />
          )}
          )
        </span>
      );
    }

    return (
      <button
        key={filter[0]}
        type='button'
        className='filter-modal__select-filter'
        data-index={filter[0]}
        onClick={this.handleItemClick}
        onKeyDown={this.handleKeyDown}
      >
        <CustomEmojiText text={filter[1]} customEmojis={this.props.customEmojis} />
        {warning}
      </button>
    );
  };

  renderCreateNew (name) {
    return (
      <button
        type='button'
        className='filter-modal__select-filter filter-modal__select-filter--create'
        onClick={this.handleNewFilterClick}
        onKeyDown={this.handleKeyDown}
      >
        <Icon id='plus' fixedWidth />
        {' '}
        <FormattedMessage id='filter_modal.select_filter.create_new' defaultMessage='Create new filter category “{name}”' values={{ name }} />
      </button>
    );
  }

  handleSearchChange = ({ target }) => {
    this.setState({ searchValue: target.value });
  }

  setListRef = c => {
    this.listNode = c;
  }

  handleKeyDown = e => {
    if (!this.listNode) {
      return;
    }

    const index = Array.from(this.listNode.childNodes).findIndex(node => node === e.currentTarget);

    let element = null;

    switch(e.key) {
    case ' ':
    case 'Enter':
      e.currentTarget.click();
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
  }

  handleSearchKeyDown = e => {
    let element = null;

    switch(e.key) {
    case 'Tab':
    case 'ArrowDown':
      element = this.listNode && this.listNode.firstChild;

      if (element) {
        element.focus();
        e.preventDefault();
        e.stopPropagation();
      }

      break;
    }
  }

  handleClear = () => {
    this.setState({ searchValue: '' });
  }

  handleItemClick = e => {
    const value = e.currentTarget.getAttribute('data-index');

    e.preventDefault();

    this.props.onSelectFilter(value);
  }

  handleNewFilterClick = e => {
    e.preventDefault();

    this.props.onNewFilter(this.state.searchValue);
  }

  render () {
    const { intl } = this.props;
    const { searchValue } = this.state;
    const isSearching = searchValue !== '';
    const results = this.search();

    return (
      <>
        <div className='filter-modal__search search'>
          <input
            className='search__input'
            type='text'
            value={searchValue}
            onChange={this.handleSearchChange}
            onKeyDown={this.handleSearchKeyDown}
            placeholder={intl.formatMessage(messages.search)}
          />

          <div role='button' tabIndex='0' className='search__icon' onClick={this.handleClear}>
            <Icon id='search' className={classNames({ active: !isSearching })} />
            <Icon id='times-circle' className={classNames({ active: isSearching })} title={intl.formatMessage(messages.clear)} />
          </div>
        </div>

        <div className='filter-modal__select-list' ref={this.setListRef}>
          {results.map(this.renderItem)}
          {isSearching && this.renderCreateNew(searchValue)}
        </div>
      </>
    );
  }

}

export default connect(mapStateToProps)(injectIntl(SelectFilter));
