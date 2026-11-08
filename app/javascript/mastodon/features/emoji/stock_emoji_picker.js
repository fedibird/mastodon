import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import {
  emptyEmojiStock,
  isEmptyEmojiStock,
  normalizeSearchKey,
  searchEmojiStock,
  toEmojiPickerCallbackPayload,
} from './emoji_stock';

// Enter from an IME reports isComposing, or keyCode 229 on some browsers.
// Those keys belong to the composition, not to emoji selection.
function isImeComposition(event) {
  const native = event && event.nativeEvent;

  return Boolean(
    (event && (event.isComposing || event.keyCode === 229))
    || (native && (native.isComposing || native.keyCode === 229)),
  );
}

const messages = defineMessages({
  label: { id: 'emoji_button.label', defaultMessage: 'Insert emoji' },
  search: { id: 'emoji_button.search', defaultMessage: 'Search...' },
  clear: { id: 'emoji_button.clear', defaultMessage: 'Clear' },
  categories: { id: 'emoji_picker.categories', defaultMessage: 'Emoji categories' },
  empty: { id: 'emoji_picker.stock_empty', defaultMessage: 'No emoji in this set' },
  notFound: { id: 'emoji_button.not_found', defaultMessage: 'No matching emojis found' },
  loading: { id: 'emoji_picker.stock_loading', defaultMessage: 'Loading emojis' },
  error: { id: 'emoji_picker.stock_error', defaultMessage: 'Could not load emojis' },
  retry: { id: 'emoji_picker.stock_retry', defaultMessage: 'Try again' },
});

// Registered stock only. No frequent category, skin-tone bar, or standard
// catalog fallback. History stays with the existing callback owner.
class StockEmojiPicker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    stock: PropTypes.shape({
      categories: PropTypes.array,
    }),
    status: PropTypes.oneOf(['idle', 'loading', 'ready', 'error']),
    query: PropTypes.string,
    onQueryChange: PropTypes.func,
    onPick: PropTypes.func,
    onRequestClose: PropTypes.func,
    onRetry: PropTypes.func,
    emojiSize: PropTypes.number,
    perLine: PropTypes.number,
    autoFocus: PropTypes.bool,
    animate: PropTypes.bool,
    theme: PropTypes.oneOf(['light', 'dark', 'auto']),
  };

  static defaultProps = {
    stock: emptyEmojiStock(),
    status: 'ready',
    onPick: () => {},
    onRequestClose: () => {},
    onRetry: () => {},
    emojiSize: 22,
    perLine: 8,
    autoFocus: false,
    animate: false,
    theme: 'light',
  };

  state = {
    query: '',
    activeKey: null,
    selectedCategoryId: null,
  };

  buttonRefs = {};

  componentDidMount() {
    if (this.props.autoFocus) {
      this.focusSearch();
    }
  }

  componentDidUpdate(prevProps) {
    if (this.props.autoFocus && !prevProps.autoFocus) {
      this.focusSearch();
    }

  }

  setSearchRef = node => {
    this.searchInput = node;
  };

  setScrollRef = node => {
    this.scroll = node;
  };

  setButtonRef = node => {
    if (!node) {
      return;
    }

    const key = node.getAttribute('data-stock-key');

    if (key) {
      this.buttonRefs[key] = node;
    }
  };

  setCategoryRef = node => {
    if (!node) {
      return;
    }

    const id = node.getAttribute('data-category-id');

    if (id) {
      if (!this.categoryNodes) {
        this.categoryNodes = {};
      }

      this.categoryNodes[id] = node;
    }
  };

  focusSearch() {
    if (this.searchInput && typeof this.searchInput.focus === 'function') {
      this.searchInput.focus();
    }
  }

  currentQuery() {
    if (this.props.query !== null && this.props.query !== undefined) {
      return this.props.query;
    }

    return this.state.query;
  }

  visibleStock() {
    return searchEmojiStock(this.props.stock, this.currentQuery());
  }

  flatItems(stock) {
    const items = [];

    stock.categories.forEach(category => {
      category.items.forEach(item => {
        items.push(item);
      });
    });

    return items;
  }

  setQuery(value) {
    if (this.props.query === null || this.props.query === undefined) {
      this.setState({ query: value, activeKey: null });
    } else {
      this.setState({ activeKey: null });
    }

    if (this.props.onQueryChange) {
      this.props.onQueryChange(value);
    }
  }

  handleQueryChange = event => {
    this.setQuery(event.target.value);
  };

  handleClear = () => {
    this.setQuery('');
    this.focusSearch();
  };

  handleCategoryClick = event => {
    const id = event.currentTarget.getAttribute('data-category-id');
    const node = this.categoryNodes && this.categoryNodes[id];
    const stock = this.visibleStock();
    const category = stock.categories.find(entry => entry.id === id);
    const first = category && category.items[0];

    if (node && this.scroll && this.scroll.contains(node)) {
      // The scroll viewport is the category's offset parent. Layout coordinates
      // stay stable during transforms, and only this viewport should scroll.
      this.scroll.scrollTop = node.offsetTop;
    }

    this.setState({
      selectedCategoryId: id,
      activeKey: first ? first.key : this.state.activeKey,
    });
  };

  findItem(key) {
    const items = this.flatItems(this.visibleStock());

    return items.find(item => item.key === key) || null;
  }

  selectItem(item, event) {
    if (!item) {
      return;
    }

    this.props.onPick(toEmojiPickerCallbackPayload(item), event);
  }

  handleEmojiMouseDown = event => {
    event.preventDefault();
  };

  handleEmojiFocus = event => {
    const key = event.currentTarget.getAttribute('data-stock-key');

    if (key && key !== this.state.activeKey) {
      this.setState({ activeKey: key });
    }
  };

  handleEmojiClick = event => {
    const key = event.currentTarget.getAttribute('data-stock-key');

    this.selectItem(this.findItem(key), event);
  };

  handleEmojiTouchEnd = event => {
    this.suppressClickTarget = event.currentTarget;
    this.handleEmojiClick(event);
  };

  handleEmojiClickFromPointer = event => {
    if (this.suppressClickTarget === event.currentTarget) {
      this.suppressClickTarget = null;
      return;
    }

    this.handleEmojiClick(event);
  };

  focusButton(key) {
    const node = this.buttonRefs[key];

    if (node && node.isConnected !== false && typeof node.focus === 'function') {
      node.focus();
    }

    // Focus is separate from state. The same activeKey must still move focus
    // after the caret returns to the search field. PureComponent would skip
    // an update that only repeats the current key.
    if (key !== this.state.activeKey) {
      this.setState({ activeKey: key });
    }
  }

  enterResults() {
    const items = this.flatItems(this.visibleStock());

    if (items.length === 0) {
      return;
    }

    const current = items.find(item => item.key === this.state.activeKey);

    this.focusButton(current ? current.key : items[0].key);
  }

  moveActive(keyName, fromKey) {
    const items = this.flatItems(this.visibleStock());

    if (items.length === 0) {
      return;
    }

    let index = items.findIndex(item => item.key === (fromKey || this.state.activeKey));
    const perLine = this.props.perLine;

    if (index < 0) {
      index = 0;
    } else if (keyName === 'ArrowRight') {
      index = Math.min(items.length - 1, index + 1);
    } else if (keyName === 'ArrowLeft') {
      index = Math.max(0, index - 1);
    } else if (keyName === 'ArrowDown') {
      index = Math.min(items.length - 1, index + perLine);
    } else if (keyName === 'ArrowUp') {
      index = Math.max(0, index - perLine);
    }

    this.focusButton(items[index].key);
  }

  handleKeyDown = event => {
    // Escape closes from the shell, once, including the mode switch and the
    // standard loading state. Handling it here as well would notify twice.
    if (isImeComposition(event)) {
      return;
    }

    const onSearch = event.target === this.searchInput;
    const focusedKey = event.target && event.target.getAttribute && event.target.getAttribute('data-stock-key');

    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight' || event.key === 'ArrowUp' || event.key === 'ArrowDown') {
      // Left and right in the search field move the caret. ArrowDown is the
      // step from the query into the result grid.
      if (onSearch) {
        if (event.key !== 'ArrowDown') {
          return;
        }

        event.preventDefault();
        this.enterResults();
        return;
      }

      if (!focusedKey) {
        return;
      }

      event.preventDefault();
      this.moveActive(event.key, focusedKey);
      return;
    }

    if (event.key !== 'Enter') {
      return;
    }

    if (!onSearch && !focusedKey) {
      return;
    }

    const items = this.flatItems(this.visibleStock());
    const active = focusedKey
      ? items.find(item => item.key === focusedKey)
      : (items.find(item => item.key === this.state.activeKey) || items[0]);

    if (!active) {
      return;
    }

    event.preventDefault();
    if (focusedKey && focusedKey !== this.state.activeKey) {
      this.setState({ activeKey: focusedKey });
    }
    this.selectItem(active, event);
  };

  imageSource(item) {
    const image = item.image || {};

    if (this.props.animate && image.animatedSrc) {
      return image.animatedSrc;
    }

    return image.src || '';
  }

  renderStatus(className, messageId) {
    const { intl } = this.props;

    return (
      <div className='emoji-mart-no-results' role='status'>
        <div className={className}>
          {intl.formatMessage(messages[messageId])}
        </div>
        {messageId === 'error' && (
          <button type='button' className='emoji-stock-picker__retry' onClick={this.props.onRetry}>
            {intl.formatMessage(messages.retry)}
          </button>
        )}
      </div>
    );
  }

  renderSearch() {
    const { intl } = this.props;

    // Stable key so a zero-result swap does not recreate the input and drop focus.
    return (
      <div key='emoji-stock-search' className='emoji-mart-search'>
        <input
          ref={this.setSearchRef}
          type='search'
          value={this.currentQuery()}
          placeholder={intl.formatMessage(messages.search)}
          aria-label={intl.formatMessage(messages.search)}
          onChange={this.handleQueryChange}
        />
        <button
          type='button'
          className='emoji-mart-search-icon'
          aria-label={intl.formatMessage(messages.clear)}
          disabled={normalizeSearchKey(this.currentQuery()) === ''}
          onClick={this.handleClear}
        >
          ×
        </button>
      </div>
    );
  }

  renderAnchorBar(stock) {
    const { intl } = this.props;
    const selected = this.state.selectedCategoryId || (stock.categories[0] && stock.categories[0].id);

    // First child when results exist. A trailing bar is hidden as the preview slot.
    return (
      <div key='emoji-stock-anchors' className='emoji-mart-bar'>
        <div className='emoji-mart-anchors' role='toolbar' aria-label={intl.formatMessage(messages.categories)}>
          {stock.categories.map(category => (
            <button
              key={category.id}
              type='button'
              className={classNames('emoji-mart-anchor', { 'emoji-mart-anchor-selected': category.id === selected })}
              data-category-id={category.id}
              aria-label={category.name}
              onClick={this.handleCategoryClick}
            >
              <span>{category.name}</span>
              <span className='emoji-mart-anchor-bar' />
            </button>
          ))}
        </div>
      </div>
    );
  }

  renderScroll(stock) {
    const { emojiSize } = this.props;

    return (
      <div key='emoji-stock-scroll' className='emoji-mart-scroll' ref={this.setScrollRef}>
        {stock.categories.map(category => (
          <section
            key={category.id}
            className='emoji-mart-category'
            data-category-id={category.id}
            ref={this.setCategoryRef}
          >
            <div className='emoji-mart-category-label'>
              <span>{category.name}</span>
            </div>
            <ul className='emoji-mart-category-list'>
              {category.items.map(item => this.renderItem(item, emojiSize))}
            </ul>
          </section>
        ))}
      </div>
    );
  }

  renderItem(item, emojiSize) {
    const image = item.image || {};
    const src = this.imageSource(item);
    const active = item.key === this.state.activeKey;

    return (
      <li key={item.key}>
        <button
          type='button'
          className='emoji-mart-emoji'
          data-stock-key={item.key}
          aria-label={item.label}
          title={image.title || item.label}
          aria-current={active ? 'true' : undefined}
          ref={this.setButtonRef}
          onFocus={this.handleEmojiFocus}
          onMouseDown={this.handleEmojiMouseDown}
          onClick={this.handleEmojiClickFromPointer}
          onTouchEnd={this.handleEmojiTouchEnd}
        >
          {src ? (
            <img
              draggable='false'
              className={classNames('emojione', { 'custom-emoji': item.selection && item.selection.custom })}
              alt=''
              src={src}
              width={emojiSize}
              height={emojiSize}
              style={{ width: emojiSize, height: emojiSize }}
            />
          ) : (
            <span>{item.label}</span>
          )}
        </button>
      </li>
    );
  }

  renderResults() {
    const { stock } = this.props;
    const query = this.currentQuery();
    const visible = this.visibleStock();
    const hasVisible = this.flatItems(visible).length > 0;
    let status = null;

    if (!hasVisible && !normalizeSearchKey(query) && isEmptyEmojiStock(stock)) {
      status = this.renderStatus('emoji-stock-picker__empty', 'empty');
    } else if (!hasVisible) {
      status = this.renderStatus('emoji-stock-picker__none', 'notFound');
    }

    return (
      <React.Fragment>
        {hasVisible ? this.renderAnchorBar(visible) : null}
        {this.renderSearch()}
        {hasVisible ? this.renderScroll(visible) : status}
      </React.Fragment>
    );
  }

  renderBody() {
    const { status } = this.props;

    if (status === 'loading') {
      return this.renderStatus('emoji-stock-picker__loading', 'loading');
    }

    if (status === 'error') {
      return this.renderStatus('emoji-stock-picker__error', 'error');
    }

    return this.renderResults();
  }

  render() {
    const { emojiSize, intl, perLine, theme } = this.props;
    const width = perLine * (emojiSize + 12) + 14;
    const resolvedTheme = theme === 'dark' ? 'dark' : 'light';

    return (
      <section
        className={`emoji-mart emoji-mart-${resolvedTheme} emoji-stock-picker`}
        style={{ width, '--emoji-stock-size': `${emojiSize}px` }}
        aria-label={intl.formatMessage(messages.label)}
        onKeyDown={this.handleKeyDown}
      >
        {this.renderBody()}
      </section>
    );
  }

}

export default injectIntl(StockEmojiPicker);
