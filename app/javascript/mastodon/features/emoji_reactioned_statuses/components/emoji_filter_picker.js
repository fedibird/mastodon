import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import Emoji from 'mastodon/components/emoji';
import { CircularProgress } from 'mastodon/components/loading_indicator';
import {
  emojiReactionCatalogMatches,
  emojiReactionFilterArray,
  emojiReactionFilterLabel,
  emojiReactionFilterValue,
  isPreferredEmojiReaction,
  normalizePreferredEmojiReactionFilters,
  sameEmojiFilters,
  togglePreferredEmojiReactionFilter,
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
  preferred: { id: 'emoji_reaction_filter.preferred', defaultMessage: 'Preferred' },
  frequent: { id: 'emoji_reaction_filter.frequent', defaultMessage: 'Frequently used' },
  pin: { id: 'emoji_reaction_filter.pin', defaultMessage: 'Pin {emoji} to preferred emoji' },
  unpin: { id: 'emoji_reaction_filter.unpin', defaultMessage: 'Unpin {emoji} from preferred emoji' },
});

function read(item, key) {
  if (!item) {
    return undefined;
  }

  if (typeof item.get === 'function') {
    return item.get(key);
  }

  return item[key];
}

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

class EmojiFilterItem extends React.PureComponent {

  static propTypes = {
    value: PropTypes.string.isRequired,
    label: PropTypes.string.isRequired,
    count: PropTypes.number,
    selected: PropTypes.bool,
    hovered: PropTypes.bool,
    preferred: PropTypes.bool,
    preferredLabel: PropTypes.string.isRequired,
    unavailableLabel: PropTypes.string,
    emoji: PropTypes.string,
    url: PropTypes.string,
    staticUrl: PropTypes.string,
    domain: PropTypes.string,
    onToggle: PropTypes.func.isRequired,
    onHover: PropTypes.func.isRequired,
    onTogglePreferred: PropTypes.func.isRequired,
  };

  handlePreferred = (event) => {
    event.preventDefault();
    event.stopPropagation();
    this.props.onTogglePreferred(this.props.value);
  };

  render() {
    const { preferred, preferredLabel, unavailableLabel } = this.props;

    return (
      <div className='emoji-reaction-filter-picker__item'>
        <EmojiFilterTile
          value={this.props.value}
          label={this.props.label}
          count={this.props.count}
          selected={this.props.selected}
          hovered={this.props.hovered}
          emoji={this.props.emoji}
          url={this.props.url}
          staticUrl={this.props.staticUrl}
          domain={this.props.domain}
          onToggle={this.props.onToggle}
          onHover={this.props.onHover}
        />
        <button
          type='button'
          className={classNames('emoji-reaction-filter-picker__preferred-toggle', { 'is-preferred': preferred })}
          aria-pressed={preferred}
          aria-label={preferredLabel}
          title={preferredLabel}
          onClick={this.handlePreferred}
        >
          <Icon id='star' />
        </button>
        {unavailableLabel && (
          <span className='emoji-reaction-filter-picker__note'>{unavailableLabel}</span>
        )}
      </div>
    );
  }

}

export default @injectIntl
class EmojiReactionFilterPicker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    catalogItems: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    appliedEmojis: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    preferredEmojis: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    isLoading: PropTypes.bool,
    loaded: PropTypes.bool,
    error: PropTypes.any,
    onApply: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    onTogglePreferred: PropTypes.func,
    autoFocus: PropTypes.bool,
  };

  static defaultProps = {
    catalogItems: [],
    appliedEmojis: [],
    preferredEmojis: [],
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

  handleTogglePreferred = (value) => {
    if (!this.props.onTogglePreferred) {
      return;
    }

    this.props.onTogglePreferred(togglePreferredEmojiReactionFilter(this.props.preferredEmojis, value));
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

  preferredValues() {
    return normalizePreferredEmojiReactionFilters(this.props.preferredEmojis);
  }

  entryMatches(value, item) {
    const query = this.state.query.trim();

    if (!query) {
      return true;
    }

    if (item) {
      return emojiReactionCatalogMatches(item, query);
    }

    const normalized = query.toLocaleLowerCase();
    const label = emojiReactionFilterLabel(value).toLocaleLowerCase();

    return value.toLocaleLowerCase().includes(normalized) || label.includes(normalized);
  }

  sections() {
    const items = emojiReactionFilterArray(this.props.catalogItems);
    const byValue = new Map();

    items.forEach(item => {
      const value = emojiReactionFilterValue(item);

      if (value && !byValue.has(value)) {
        byValue.set(value, item);
      }
    });

    const preferredValues = this.preferredValues();
    const preferredSet = new Set(preferredValues);
    const settled = this.catalogSettled();
    const preferred = [];
    const remaining = [];
    const seenRemaining = new Set();

    preferredValues.forEach(value => {
      const item = byValue.get(value) || null;

      if (!item && !settled) {
        return;
      }

      if (!this.entryMatches(value, item)) {
        return;
      }

      preferred.push({ value, item, missing: !item });
    });

    items.forEach(item => {
      const value = emojiReactionFilterValue(item);

      if (!value || preferredSet.has(value) || seenRemaining.has(value)) {
        return;
      }

      if (!this.entryMatches(value, item)) {
        return;
      }

      seenRemaining.add(value);
      remaining.push({ value, item, missing: false });
    });

    return { preferred, remaining };
  }

  missingValues() {
    if (!this.catalogSettled()) {
      return [];
    }

    const known = this.knownValues();
    const preferred = new Set(this.preferredValues());
    const query = this.state.query.trim().toLocaleLowerCase();

    return this.state.draft.filter(value => {
      if (known.has(value) || preferred.has(value)) {
        return false;
      }

      if (!query) {
        return true;
      }

      const label = emojiReactionFilterLabel(value).toLocaleLowerCase();

      return value.toLocaleLowerCase().includes(query) || label.includes(query);
    });
  }

  renderItem(entry) {
    const { intl } = this.props;
    const { value, item, missing } = entry;
    const label = item ? emojiReactionFilterLabel(item) : emojiReactionFilterLabel(value);
    const custom = Boolean(read(item, 'custom'));
    const domain = read(item, 'domain');
    const url = read(item, 'url');
    const staticUrl = read(item, 'static_url');
    const name = read(item, 'name');
    const canRenderImage = Boolean(item) && (!custom || url || staticUrl);
    const preferred = isPreferredEmojiReaction(this.props.preferredEmojis, value);

    return (
      <EmojiFilterItem
        key={value}
        value={value}
        label={label}
        count={item ? (Number(read(item, 'count')) || 0) : 0}
        selected={this.state.draft.indexOf(value) !== -1}
        hovered={this.state.hovered === value}
        preferred={preferred}
        preferredLabel={intl.formatMessage(preferred ? messages.unpin : messages.pin, { emoji: label })}
        unavailableLabel={missing ? intl.formatMessage(messages.unavailable) : null}
        emoji={canRenderImage ? String(name || '') : undefined}
        url={custom ? (url || undefined) : undefined}
        staticUrl={custom ? (staticUrl || undefined) : undefined}
        domain={custom && domain ? domain : undefined}
        onToggle={this.handleToggle}
        onHover={this.handleHover}
        onTogglePreferred={this.handleTogglePreferred}
      />
    );
  }

  renderGrid(entries) {
    return (
      <div className='emoji-reaction-filter-picker__grid'>
        {entries.map(entry => this.renderItem(entry))}
      </div>
    );
  }

  renderGroup(message, entries) {
    if (entries.length === 0) {
      return null;
    }

    return (
      <section className='emoji-reaction-filter-picker__group'>
        <h3 className='emoji-reaction-filter-picker__section-heading'>
          {this.props.intl.formatMessage(message)}
        </h3>
        {this.renderGrid(entries)}
      </section>
    );
  }

  renderBody() {
    const { intl, isLoading, error } = this.props;
    const items = emojiReactionFilterArray(this.props.catalogItems);
    const { preferred, remaining } = this.sections();
    const missing = this.missingValues();
    const query = this.state.query.trim();
    const hasContent = preferred.length > 0 || remaining.length > 0 || missing.length > 0;
    const showFrequentHeading = this.preferredValues().length > 0;

    if (isLoading && items.length === 0) {
      return (
        <div className='emoji-reaction-filter-picker__status'>
          <CircularProgress size={28} strokeWidth={3} />
        </div>
      );
    }

    if (error && items.length === 0 && !hasContent) {
      return <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.error)}</p>;
    }

    if (!query && items.length === 0 && !hasContent) {
      return <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.empty)}</p>;
    }

    if (!hasContent) {
      return <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.noResults)}</p>;
    }

    return (
      <React.Fragment>
        {error && items.length === 0 && (
          <p className='emoji-reaction-filter-picker__message'>{intl.formatMessage(messages.error)}</p>
        )}
        {this.renderGroup(messages.preferred, preferred)}
        {remaining.length > 0 && (showFrequentHeading ? this.renderGroup(messages.frequent, remaining) : this.renderGrid(remaining))}
        {missing.length > 0 && (
          <div className='emoji-reaction-filter-picker__missing'>
            <p className='emoji-reaction-filter-picker__section'>{intl.formatMessage(messages.unavailable)}</p>
            {this.renderGrid(missing.map(value => ({ value, item: null, missing: false })))}
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
