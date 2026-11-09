import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import {
  emptyEmojiStock,
  firstGrapheme,
  isEmptyEmojiStock,
  normalizeSearchKey,
  searchEmojiStock,
  toEmojiPickerCallbackPayload,
} from './emoji_stock';
import { openEmojiActions } from './emoji_actions/bus';
import { datasetFromReference, referenceFromStockItem } from './emoji_actions/reference';
import { attachLongPressGesture } from './long_press';

const actionMessages = defineMessages({
  manage: { id: 'emoji_actions.manage', defaultMessage: 'Emoji actions' },
});

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

class CategoryHeading extends React.PureComponent {

  static propTypes = {
    heading: PropTypes.object,
    name: PropTypes.string.isRequired,
    animate: PropTypes.bool,
  };

  state = { failedSource: null };

  source() {
    const image = this.props.heading && this.props.heading.image;

    return image && ((this.props.animate && image.animatedSrc) || image.src);
  }

  handleError = () => {
    this.setState({ failedSource: this.source() });
  };

  render() {
    const { heading, name } = this.props;
    const source = this.source();
    const text = (heading && heading.text) || firstGrapheme(name);

    return (
      <span className='emoji-stock-picker__heading' aria-hidden='true'>
        {source && source !== this.state.failedSource ? (
          <img src={source} alt='' draggable='false' onError={this.handleError} />
        ) : text}
      </span>
    );
  }

}

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
    selectedCategoryId: PropTypes.string,
    editMode: PropTypes.bool,
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
    editMode: false,
  };

  state = {
    query: '',
    activeKey: null,
    selectedCategoryId: null,
  };

  buttonRefs = {};
  longPressCleanups = new Map();

  componentDidMount() {
    document.addEventListener('touchstart', this.handleAdditionalTouch, true);
    if (this.props.autoFocus) {
      this.focusSearch();
    }

    this.scrollToCategory(this.props.selectedCategoryId);
  }

  componentWillUnmount() {
    document.removeEventListener('touchstart', this.handleAdditionalTouch, true);
    this.touch = null;
    this.longPressCleanups.forEach(detach => detach());
    this.longPressCleanups.clear();
  }

  componentDidUpdate(prevProps) {
    if (this.props.autoFocus && !prevProps.autoFocus) {
      this.focusSearch();
    }

    if (this.props.selectedCategoryId && (
      prevProps.selectedCategoryId !== this.props.selectedCategoryId
      || prevProps.stock !== this.props.stock
      || prevProps.emojiSize !== this.props.emojiSize
      || prevProps.query !== this.props.query
    )) {
      const moved = this.scrollToCategory(this.props.selectedCategoryId);

      if (moved && this.state.selectedCategoryId !== this.props.selectedCategoryId) {
        this.setState({ selectedCategoryId: this.props.selectedCategoryId });
      }
    }

    this.pruneLongPressHandlers();
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

    if (!key) {
      return;
    }

    const previous = this.buttonRefs[key];

    if (previous && previous !== node && this.longPressCleanups.has(key)) {
      this.longPressCleanups.get(key)();
      this.longPressCleanups.delete(key);
    }

    this.buttonRefs[key] = node;

    if (!this.longPressCleanups.has(key)) {
      const detach = attachLongPressGesture(node, {
        onLongPress: event => {
          this.longPressOpened = true;
          this.openActionsForStockKey(key, node, event);
        },
      });
      this.longPressCleanups.set(key, detach);
    }
  };

  pruneLongPressHandlers = () => {
    this.longPressCleanups.forEach((detach, key) => {
      const node = this.buttonRefs[key];

      if (!node || node.isConnected === false) {
        detach();
        this.longPressCleanups.delete(key);
        delete this.buttonRefs[key];
      }
    });
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

  scrollToCategory(id) {
    const node = this.categoryNodes && this.categoryNodes[id];

    if (node && this.scroll && this.scroll.contains(node)) {
      // Only the picker viewport moves, including in an embedded preview.
      this.scroll.scrollTop = node.offsetTop;
      return true;
    }

    return false;
  }

  handleCategoryClick = event => {
    const id = event.currentTarget.getAttribute('data-category-id');
    const stock = this.visibleStock();
    const category = stock.categories.find(entry => entry.id === id);
    const first = category && category.items[0];

    this.scrollToCategory(id);

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

  handleEmojiTouchStart = event => {
    const touch = event.touches && event.touches[0];

    this.touch = touch && event.touches.length === 1 ? {
      identifier: touch.identifier,
      target: event.currentTarget,
      x: touch.clientX,
      y: touch.clientY,
      scrollTop: this.scroll && this.scroll.scrollTop,
      moved: false,
    } : null;
  };

  handleAdditionalTouch = event => {
    // A second finger may land on the search field or outside the picker and
    // lift again without delivering a touchmove to the original emoji button.
    if (this.touch && event.touches && event.touches.length > 1) {
      this.touch.moved = true;
    }
  };

  handleEmojiTouchMove = event => {
    if (!this.touch) {
      return;
    }

    const touch = event.touches && Array.from(event.touches).find(point => point.identifier === this.touch.identifier);

    if (!touch || event.touches.length !== 1 || Math.hypot(touch.clientX - this.touch.x, touch.clientY - this.touch.y) > 8) {
      this.touch.moved = true;
    }
  };

  suppressTouchClick(target) {
    this.suppressedClick = { target, until: Date.now() + 1000 };
  }

  handleEmojiTouchCancel = event => {
    this.suppressTouchClick(event.currentTarget);
    this.touch = null;
  };

  handleEmojiTouchEnd = event => {
    const start = this.touch;
    const end = start && event.changedTouches && Array.from(event.changedTouches).find(point => point.identifier === start.identifier);

    this.touch = null;
    this.suppressTouchClick(event.currentTarget);

    if (this.longPressOpened) {
      this.longPressOpened = false;
      return;
    }

    if (!start || !end || start.moved || start.target !== event.currentTarget
      || (event.touches && event.touches.length > 0)
      || (this.scroll && start.scrollTop !== this.scroll.scrollTop)
      || Math.hypot(end.clientX - start.x, end.clientY - start.y) > 8) {
      return;
    }

    event.preventDefault();
    this.handleEmojiClick(event);
  };

  handleEmojiClickFromPointer = event => {
    const suppressed = this.suppressedClick;

    if (event.detail !== 0 && suppressed && suppressed.target === event.currentTarget && Date.now() < suppressed.until) {
      this.suppressedClick = null;
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

  verticalTargetIndex(items, index, direction) {
    const current = this.buttonRefs[items[index].key];
    const origin = current && current.getBoundingClientRect();

    if (!origin || !origin.width || !origin.height) {
      return Math.max(0, Math.min(items.length - 1, index + direction * this.props.perLine));
    }

    const center = origin.left + origin.width / 2;
    let target = index;
    let nearestRow = Infinity;
    let nearestColumn = Infinity;

    // Wide images and category boundaries change the number of items per row.
    // Measure the current visible buttons so resizing and filtering also work.
    items.forEach((item, candidate) => {
      const button = this.buttonRefs[item.key];

      if (!button || button.isConnected === false) {
        return;
      }

      const rect = button.getBoundingClientRect();
      const row = direction * (rect.top - origin.top);
      const column = Math.abs(rect.left + rect.width / 2 - center);

      // Ignore the current row, allowing for fractional-pixel alignment.
      if (!rect.width || !rect.height || row <= 1) {
        return;
      }

      if (row < nearestRow - 1 || (Math.abs(row - nearestRow) <= 1 && column < nearestColumn)) {
        target = candidate;
        nearestRow = row;
        nearestColumn = column;
      }
    });

    return target;
  }

  moveActive(keyName, fromKey) {
    const items = this.flatItems(this.visibleStock());

    if (items.length === 0) {
      return;
    }

    let index = items.findIndex(item => item.key === (fromKey || this.state.activeKey));

    if (index < 0) {
      index = 0;
    } else if (keyName === 'ArrowRight') {
      index = Math.min(items.length - 1, index + 1);
    } else if (keyName === 'ArrowLeft') {
      index = Math.max(0, index - 1);
    } else if (keyName === 'ArrowDown' || keyName === 'ArrowUp') {
      index = this.verticalTargetIndex(items, index, keyName === 'ArrowDown' ? 1 : -1);
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
    const requested = this.state.selectedCategoryId || this.props.selectedCategoryId;
    const selected = stock.categories.some(category => category.id === requested)
      ? requested : (stock.categories[0] && stock.categories[0].id);

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
              title={category.name}
              aria-pressed={category.id === selected}
              onClick={this.handleCategoryClick}
            >
              <CategoryHeading heading={category.heading} name={category.name} animate={this.props.animate} />
              <span className='emoji-mart-anchor-bar' />
            </button>
          ))}
        </div>
      </div>
    );
  }

  renderScroll(stock, status) {
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
        {status}
      </div>
    );
  }

  openActionsForStockKey = (key, anchor, event) => {
    const item = this.flatItems(this.visibleStock()).find(entry => entry.key === key);

    if (!item) {
      return;
    }

    const reference = referenceFromStockItem(item);

    if (!reference) {
      return;
    }

    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }

    openEmojiActions(reference, {
      anchor: anchor || null,
      source: 'personal_picker',
    });
  };

  handleItemActionsClick = event => {
    const key = event.currentTarget.getAttribute('data-stock-key');

    event.preventDefault();
    event.stopPropagation();
    this.openActionsForStockKey(key, event.currentTarget, event);
  };

  handleActionsMouseDown = event => {
    event.preventDefault();
  };

  handleActionsTouchStart = event => {
    event.stopPropagation();
  };

  renderItem(item, emojiSize) {
    const { intl, editMode } = this.props;
    const image = item.image || {};
    const src = this.imageSource(item);
    const active = item.key === this.state.activeKey;
    const custom = item.selection && item.selection.custom;
    const reference = referenceFromStockItem(item);
    const actionDataset = datasetFromReference(reference);
    const actionProps = {
      'data-emoji-actions': '1',
      'data-emoji-source': 'personal_picker',
    };

    if (actionDataset.emojiKind) actionProps['data-emoji-kind'] = actionDataset.emojiKind;
    if (actionDataset.emojiNative) actionProps['data-emoji-native'] = actionDataset.emojiNative;
    if (actionDataset.emojiScope) actionProps['data-emoji-scope'] = actionDataset.emojiScope;
    if (actionDataset.emojiCustomEmojiId) actionProps['data-emoji-custom-emoji-id'] = actionDataset.emojiCustomEmojiId;
    if (actionDataset.emojiDomain) actionProps['data-emoji-domain'] = actionDataset.emojiDomain;
    if (actionDataset.emojiShortcode) actionProps['data-emoji-shortcode'] = actionDataset.emojiShortcode;

    let imageWidth = emojiSize;

    // Reserve known aspect ratios before loading; older stock without metadata
    // uses the image's intrinsic width. CSS caps wide images in both cases.
    if (custom) {
      const hasDimensions = Number.isFinite(image.width) && image.width > 0 && Number.isFinite(image.height) && image.height > 0;

      imageWidth = hasDimensions ? emojiSize * image.width / image.height : 'auto';
    }

    return (
      <li key={item.key} className={classNames('emoji-stock-picker__item', { 'emoji-stock-picker__item--editing': editMode })}>
        <button
          type='button'
          className='emoji-mart-emoji'
          data-stock-key={item.key}
          {...actionProps}
          aria-label={item.label}
          title={image.title || item.label}
          aria-current={active ? 'true' : undefined}
          ref={this.setButtonRef}
          onFocus={this.handleEmojiFocus}
          onMouseDown={this.handleEmojiMouseDown}
          onClick={this.handleEmojiClickFromPointer}
          onTouchStart={this.handleEmojiTouchStart}
          onTouchMove={this.handleEmojiTouchMove}
          onTouchEnd={this.handleEmojiTouchEnd}
          onTouchCancel={this.handleEmojiTouchCancel}
        >
          {src ? (
            <img
              draggable='false'
              className={classNames('emoji-stock-picker__image', { 'custom-emoji': custom })}
              alt=''
              src={src}
              width={imageWidth === 'auto' ? undefined : imageWidth}
              height={emojiSize}
              style={{ width: imageWidth, height: emojiSize }}
            />
          ) : (
            <span>{item.label}</span>
          )}
        </button>
        {editMode && reference && (
          <button
            type='button'
            className='emoji-actions-trigger emoji-stock-picker__actions'
            data-stock-key={item.key}
            aria-label={intl.formatMessage(actionMessages.manage)}
            title={intl.formatMessage(actionMessages.manage)}
            onClick={this.handleItemActionsClick}
            onMouseDown={this.handleActionsMouseDown}
            onTouchStart={this.handleActionsTouchStart}
          >
            ⋯
          </button>
        )}
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
        {visible.categories.length > 0 ? this.renderAnchorBar(visible) : null}
        {this.renderSearch()}
        {visible.categories.length > 0 ? this.renderScroll(visible, status) : status}
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
