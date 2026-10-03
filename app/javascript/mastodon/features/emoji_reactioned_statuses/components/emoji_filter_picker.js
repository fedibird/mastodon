import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import Emoji from 'mastodon/components/emoji';
import { CircularProgress } from 'mastodon/components/loading_indicator';
import {
  emojiReactionFilterArray,
  emojiReactionFilterLabel,
  emojiReactionFilterValue,
  filterEmojiReactionCatalog,
  sameEmojiFilters,
} from '../utils';

const messages = defineMessages({
  title: { id: 'emoji_reaction_filter.title', defaultMessage: 'Filter by reaction emoji' },
  search: { id: 'emoji_reaction_filter.search', defaultMessage: 'Search emoji you have used' },
  apply: { id: 'emoji_reaction_filter.apply', defaultMessage: 'Apply' },
  cancel: { id: 'emoji_reaction_filter.cancel', defaultMessage: 'Cancel' },
  clear: { id: 'emoji_reaction_filter.clear', defaultMessage: 'Clear all' },
  selected: { id: 'emoji_reaction_filter.selected', defaultMessage: '{count} emojis selected' },
  noneSelected: { id: 'emoji_reaction_filter.none_selected', defaultMessage: 'None selected' },
  noResults: { id: 'emoji_reaction_filter.no_results', defaultMessage: 'No matching reaction emoji' },
  empty: { id: 'emoji_reaction_filter.empty', defaultMessage: 'No reaction emoji in use yet' },
  unavailable: { id: 'emoji_reaction_filter.unavailable', defaultMessage: 'Emoji not currently used' },
  error: { id: 'emoji_reaction_filter.error', defaultMessage: 'Could not load reaction emoji' },
});

class EmojiFilterTile extends React.PureComponent {

  static propTypes = {
    value: PropTypes.string.isRequired,
    label: PropTypes.string.isRequired,
    count: PropTypes.number,
    selected: PropTypes.bool,
    hovered: PropTypes.bool,
    emoji: PropTypes.string,
    url: PropTypes.string,
    staticUrl: PropTypes.string,
    domain: PropTypes.string,
    onToggle: PropTypes.func.isRequired,
    onHover: PropTypes.func.isRequired,
  };

  handleClick = () => {
    this.props.onToggle(this.props.value);
  };

  handleMouseEnter = () => {
    this.props.onHover(this.props.value);
  };

  handleMouseLeave = () => {
    this.props.onHover(null);
  };

  render() {
    const { label, count, selected, hovered, emoji, url, staticUrl, domain } = this.props;

    return (
      <button
        type='button'
        className={classNames('emoji-reaction-filter-picker__tile', { 'is-selected': selected })}
        aria-pressed={selected}
        aria-label={label}
        onClick={this.handleClick}
        onMouseEnter={this.handleMouseEnter}
        onMouseLeave={this.handleMouseLeave}
      >
        {emoji ? (
          <Emoji
            className='emoji-reaction-filter-picker__glyph'
            emoji={emoji}
            url={url}
            static_url={staticUrl}
            domain={domain}
            hovered={hovered}
          />
        ) : (
          <span className='emoji-reaction-filter-picker__fallback'>{label}</span>
        )}
        <span className='emoji-reaction-filter-picker__count'>{count}</span>
        {selected && <Icon id='check' className='emoji-reaction-filter-picker__check' />}
      </button>
    );
  }

}

export default @injectIntl
class EmojiReactionFilterPicker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    catalogItems: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    appliedEmojis: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    isLoading: PropTypes.bool,
    loaded: PropTypes.bool,
    error: PropTypes.any,
    onApply: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    autoFocus: PropTypes.bool,
  };

  static defaultProps = {
    catalogItems: [],
    appliedEmojis: [],
    isLoading: false,
    loaded: false,
    error: null,
    autoFocus: true,
  };

  constructor(props) {
    super(props);
    this.state = {
      draft: emojiReactionFilterArray(props.appliedEmojis),
      query: '',
      hovered: null,
    };
  }

  componentDidMount() {
    if (this.props.autoFocus && this.searchInput) {
      this.searchInput.focus();
    }
  }

  setSearchRef = (node) => {
    this.searchInput = node;
  };

  handleQuery = (event) => {
    this.setState({ query: event.target.value });
  };

  handleToggle = (value) => {
    this.setState(({ draft }) => {
      const index = draft.indexOf(value);

      if (index === -1) {
        return { draft: draft.concat(value) };
      }

      return { draft: draft.slice(0, index).concat(draft.slice(index + 1)) };
    });
  };

  handleHover = (value) => {
    this.setState({ hovered: value });
  };

  handleClear = () => {
    this.setState({ draft: [] });
  };

  handleCancel = () => {
    this.props.onClose();
  };

  handleApply = () => {
    if (this.applyDisabled()) {
      return;
    }

    this.props.onApply(this.state.draft.slice());
  };

  handleKeyDown = (event) => {
    if (event.key !== 'Escape') {
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    this.props.onClose();
  };

  applyDisabled() {
    return sameEmojiFilters(this.state.draft, this.props.appliedEmojis);
  }

  knownValues() {
    return new Set(emojiReactionFilterArray(this.props.catalogItems).map(emojiReactionFilterValue));
  }

  catalogSettled() {
    const items = emojiReactionFilterArray(this.props.catalogItems);

    return this.props.loaded || items.length > 0 || Boolean(this.props.error);
  }

  missingValues() {
    if (!this.catalogSettled()) {
      return [];
    }

    const known = this.knownValues();
    const query = this.state.query.trim().toLocaleLowerCase();

    return this.state.draft.filter(value => {
      if (known.has(value)) {
        return false;
      }

      if (!query) {
        return true;
      }

      const label = emojiReactionFilterLabel(value).toLocaleLowerCase();

      return value.toLocaleLowerCase().includes(query) || label.includes(query);
    });
  }

  renderTile(item) {
    const value = emojiReactionFilterValue(item);
    const custom = Boolean(typeof item.get === 'function' ? item.get('custom') : item.custom);
    const domain = typeof item.get === 'function' ? item.get('domain') : item.domain;
    const url = typeof item.get === 'function' ? item.get('url') : item.url;
    const staticUrl = typeof item.get === 'function' ? item.get('static_url') : item.static_url;
    const count = typeof item.get === 'function' ? item.get('count') : item.count;
    const name = typeof item.get === 'function' ? item.get('name') : item.name;
    const canRenderImage = !custom || url || staticUrl;

    return (
      <EmojiFilterTile
        key={value}
        value={value}
        label={emojiReactionFilterLabel(item)}
        count={Number(count) || 0}
        selected={this.state.draft.indexOf(value) !== -1}
        hovered={this.state.hovered === value}
        emoji={canRenderImage ? String(name || '') : undefined}
        url={custom ? (url || undefined) : undefined}
        staticUrl={custom ? (staticUrl || undefined) : undefined}
        domain={custom && domain ? domain : undefined}
        onToggle={this.handleToggle}
        onHover={this.handleHover}
      />
    );
  }

  renderMissingTile(value) {
    return (
      <EmojiFilterTile
        key={value}
        value={value}
        label={emojiReactionFilterLabel(value)}
        count={0}
        selected={this.state.draft.indexOf(value) !== -1}
        hovered={this.state.hovered === value}
        onToggle={this.handleToggle}
        onHover={this.handleHover}
      />
    );
  }

  renderBody() {
    const { intl, isLoading, error } = this.props;
    const items = emojiReactionFilterArray(this.props.catalogItems);
    const matches = filterEmojiReactionCatalog(items, this.state.query);
    const missing = this.missingValues();
    const query = this.state.query.trim();

    if (isLoading && items.length === 0) {
      return (
        <div className='emoji-reaction-filter-picker__status'>
          <CircularProgress size={28} strokeWidth={3} />
        </div>
      );
    }

    if (error && items.length === 0 && missing.length === 0) {
      return <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.error)}</p>;
    }

    if (!query && items.length === 0 && missing.length === 0) {
      return <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.empty)}</p>;
    }

    if (matches.length === 0 && missing.length === 0) {
      return <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.noResults)}</p>;
    }

    return (
      <React.Fragment>
        {error && items.length === 0 && (
          <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.error)}</p>
        )}
        {matches.length > 0 && (
          <div className='emoji-reaction-filter-picker__grid'>
            {matches.map(item => this.renderTile(item))}
          </div>
        )}
        {missing.length > 0 && (
          <div className='emoji-reaction-filter-picker__missing'>
            <p className='emoji-reaction-filter-picker__section'>{intl.formatMessage(messages.unavailable)}</p>
            <div className='emoji-reaction-filter-picker__grid'>
              {missing.map(value => this.renderMissingTile(value))}
            </div>
          </div>
        )}
      </React.Fragment>
    );
  }

  render() {
    const { intl } = this.props;
    const count = this.state.draft.length;
    const countLabel = count === 0
      ? intl.formatMessage(messages.noneSelected)
      : intl.formatMessage(messages.selected, { count });

    return (
      <div
        className='emoji-reaction-filter-picker'
        role='dialog'
        aria-label={intl.formatMessage(messages.title)}
        onKeyDown={this.handleKeyDown}
      >
        <div className='emoji-reaction-filter-picker__header'>
          {intl.formatMessage(messages.title)}
        </div>
        <label className='emoji-reaction-filter-picker__search'>
          <Icon id='search' />
          <input
            ref={this.setSearchRef}
            type='search'
            value={this.state.query}
            placeholder={intl.formatMessage(messages.search)}
            aria-label={intl.formatMessage(messages.search)}
            onChange={this.handleQuery}
          />
        </label>
        <div className='emoji-reaction-filter-picker__body'>
          {this.renderBody()}
        </div>
        <div className='emoji-reaction-filter-picker__footer'>
          <div className='emoji-reaction-filter-picker__summary' aria-live='polite'>
            {countLabel}
          </div>
          <div className='emoji-reaction-filter-picker__actions'>
            <button type='button' className='emoji-reaction-filter-picker__button' onClick={this.handleClear}>
              {intl.formatMessage(messages.clear)}
            </button>
            <button type='button' className='emoji-reaction-filter-picker__button' onClick={this.handleCancel}>
              {intl.formatMessage(messages.cancel)}
            </button>
            <button
              type='button'
              className='emoji-reaction-filter-picker__button emoji-reaction-filter-picker__button--apply'
              onClick={this.handleApply}
              disabled={this.applyDisabled()}
            >
              {intl.formatMessage(messages.apply)}
            </button>
          </div>
        </div>
      </div>
    );
  }

}
