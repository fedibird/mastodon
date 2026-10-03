import React from 'react';
import ReactDOM from 'react-dom';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import Emoji from 'mastodon/components/emoji';
import { CircularProgress } from 'mastodon/components/loading_indicator';
import {
  insertionIndexForPoint,
  LONG_PRESS_DELAY,
  pointerPastThreshold,
  pointWithinRect,
  preferredDropIndex,
} from '../emoji_filter_drag';
import {
  emojiReactionCatalogMatches,
  emojiReactionFilterArray,
  emojiReactionFilterLabel,
  emojiReactionFilterValue,
  isPreferredEmojiReaction,
  normalizePreferredEmojiReactionFilters,
  placePreferredEmojiReactionFilter,
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
  preferred: { id: 'emoji_reaction_filter.preferred', defaultMessage: 'Pinned' },
  frequent: { id: 'emoji_reaction_filter.frequent', defaultMessage: 'Frequently used' },
  pin: { id: 'emoji_reaction_filter.pin', defaultMessage: 'Pin {emoji}' },
  unpin: { id: 'emoji_reaction_filter.unpin', defaultMessage: 'Unpin {emoji}' },
  editPinned: { id: 'emoji_reaction_filter.edit_pinned', defaultMessage: 'Edit pinned' },
  done: { id: 'emoji_reaction_filter.done', defaultMessage: 'Done' },
  dropHint: { id: 'emoji_reaction_filter.drop_hint', defaultMessage: 'Drag here to pin' },
});

const CLICK_SWALLOW_MS = 700;

function read(item, key) {
  if (!item) {
    return undefined;
  }

  if (typeof item.get === 'function') {
    return item.get(key);
  }

  return item[key];
}

function primaryButton(event) {
  return typeof event.button !== 'number' || event.button === 0;
}

function pointerIdOf(event) {
  const nativeId = event.nativeEvent ? event.nativeEvent.pointerId : undefined;
  const id = event.pointerId !== undefined && event.pointerId !== null ? event.pointerId : nativeId;

  return id === undefined || id === null ? 1 : id;
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
    onPressStart: PropTypes.func,
    onContextMenu: PropTypes.func,
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

  handlePointerDown = (event) => {
    if (!primaryButton(event) || !this.props.onPressStart) {
      return;
    }

    this.props.onPressStart(this.props.value, event);
  };

  handleContextMenu = (event) => {
    if (this.props.onContextMenu) {
      this.props.onContextMenu(event);
    }
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
        onPointerDown={this.handlePointerDown}
        onContextMenu={this.handleContextMenu}
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
    showPreferredToggle: PropTypes.bool,
    preferredLabel: PropTypes.string.isRequired,
    unavailableLabel: PropTypes.string,
    emoji: PropTypes.string,
    url: PropTypes.string,
    staticUrl: PropTypes.string,
    domain: PropTypes.string,
    pinned: PropTypes.bool,
    dragging: PropTypes.bool,
    insertBefore: PropTypes.bool,
    insertAfter: PropTypes.bool,
    onToggle: PropTypes.func.isRequired,
    onHover: PropTypes.func.isRequired,
    onTogglePreferred: PropTypes.func.isRequired,
    onPressStart: PropTypes.func,
    onContextMenu: PropTypes.func,
  };

  handlePreferred = (event) => {
    event.preventDefault();
    event.stopPropagation();
    this.props.onTogglePreferred(this.props.value);
  };

  render() {
    const { preferred, preferredLabel, unavailableLabel, showPreferredToggle, pinned, dragging, insertBefore, insertAfter } = this.props;

    return (
      <div
        className={classNames('emoji-reaction-filter-picker__item', {
          'is-drag-source': dragging,
          'is-insert-before': insertBefore,
          'is-insert-after': insertAfter,
        })}
        data-pin-value={pinned ? this.props.value : undefined}
      >
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
          onPressStart={this.props.onPressStart}
          onContextMenu={this.props.onContextMenu}
        />
        {showPreferredToggle && (
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
        )}
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
      editingPinned: false,
      drag: null,
      preview: null,
    };
    this.pressOrigin = null;
    this.gestureMoved = false;
    this.dragStarted = false;
    this.previewShown = false;
    this.dragSnapshot = null;
    this.captureTarget = null;
    this.capturePointerId = null;
  }

  componentDidMount() {
    if (this.props.autoFocus && this.searchInput) {
      this.searchInput.focus();
    }
  }

  componentWillUnmount() {
    this.releaseGesture();
    this.disarmClickSwallow();
  }

  setSearchRef = (node) => {
    this.searchInput = node;
  };

  setPinnedZoneRef = (node) => {
    this.pinnedZone = node;
  };

  bindGestureListeners() {
    document.addEventListener('pointermove', this.handleDocumentPointerMove, true);
    document.addEventListener('pointerup', this.handleDocumentPointerUp, true);
    document.addEventListener('pointercancel', this.handleDocumentPointerCancel, true);
  }

  unbindGestureListeners() {
    document.removeEventListener('pointermove', this.handleDocumentPointerMove, true);
    document.removeEventListener('pointerup', this.handleDocumentPointerUp, true);
    document.removeEventListener('pointercancel', this.handleDocumentPointerCancel, true);
  }

  clearPressTimer() {
    if (this.longPressTimer) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = null;
    }
  }

  capturePointer(event) {
    const target = event.currentTarget;
    const pointerId = pointerIdOf(event);

    if (!target || typeof target.setPointerCapture !== 'function') {
      return;
    }

    try {
      target.setPointerCapture(pointerId);
      this.captureTarget = target;
      this.capturePointerId = pointerId;
    } catch (error) {
      this.captureTarget = null;
      this.capturePointerId = null;
    }
  }

  releasePointer() {
    const target = this.captureTarget;
    const pointerId = this.capturePointerId;

    this.captureTarget = null;
    this.capturePointerId = null;

    if (!target || pointerId === null || typeof target.releasePointerCapture !== 'function') {
      return;
    }

    try {
      if (typeof target.hasPointerCapture !== 'function' || target.hasPointerCapture(pointerId)) {
        target.releasePointerCapture(pointerId);
      }
    } catch (error) {
      // The pointer may already have been released by the browser.
    }
  }

  releaseGesture() {
    this.clearPressTimer();
    this.releasePointer();
    this.unbindGestureListeners();
    this.pressOrigin = null;
    this.gestureMoved = false;
    this.dragStarted = false;
    this.previewShown = false;
    this.dragSnapshot = null;
  }

  disarmClickSwallow() {
    if (this.clickSwallowTimer) {
      clearTimeout(this.clickSwallowTimer);
      this.clickSwallowTimer = null;
    }

    if (this.clickSwallow) {
      document.removeEventListener('click', this.clickSwallow, true);
      this.clickSwallow = null;
    }
  }

  armClickSwallow() {
    this.disarmClickSwallow();
    this.clickSwallow = (event) => {
      event.preventDefault();
      event.stopPropagation();
      this.disarmClickSwallow();
    };
    document.addEventListener('click', this.clickSwallow, true);
    this.clickSwallowTimer = setTimeout(() => this.disarmClickSwallow(), CLICK_SWALLOW_MS);
  }

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

  handleToggleEditing = () => {
    this.releaseGesture();
    this.setState(({ editingPinned }) => ({
      editingPinned: !editingPinned,
      drag: null,
      preview: null,
    }));
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

  handleContextMenu = (event) => {
    if (this.previewShown) {
      event.preventDefault();
    }
  };

  handlePressStart = (value, event) => {
    this.releaseGesture();
    this.pressOrigin = {
      value,
      x: event.clientX,
      y: event.clientY,
      pointerId: pointerIdOf(event),
    };
    this.capturePointer(event);
    this.longPressTimer = setTimeout(() => this.openPreview(value), LONG_PRESS_DELAY);
    this.bindGestureListeners();
  };

  handleDocumentPointerMove = (event) => {
    if (!this.pressOrigin || pointerIdOf(event) !== this.pressOrigin.pointerId) {
      return;
    }

    const point = { x: event.clientX, y: event.clientY };

    if (!this.gestureMoved && pointerPastThreshold(this.pressOrigin, point)) {
      this.gestureMoved = true;
      this.clearPressTimer();

      if (this.previewShown) {
        return;
      }

      if (this.state.editingPinned) {
        this.dragStarted = true;
        this.updateDrag(point);
      }

      return;
    }

    if (this.dragStarted) {
      this.updateDrag(point);
    }
  };

  handleDocumentPointerUp = (event) => {
    this.finishGesture(event, true);
  };

  handleDocumentPointerCancel = (event) => {
    this.finishGesture(event, false);
  };

  finishGesture(event, commit) {
    if (!this.pressOrigin || pointerIdOf(event) !== this.pressOrigin.pointerId) {
      return;
    }

    const snapshot = this.dragSnapshot;
    const shouldCommit = Boolean(commit && this.dragStarted && snapshot && snapshot.overZone);
    const shouldConsume = this.gestureMoved || this.previewShown || this.dragStarted;
    const shouldReset = this.previewShown || this.dragStarted || this.state.preview || this.state.drag;

    this.releaseGesture();

    if (shouldConsume) {
      this.armClickSwallow();
    }

    if (shouldCommit) {
      this.commitDrop(snapshot);
    }

    if (shouldReset) {
      this.setState({ preview: null, drag: null });
    }
  }

  updateDrag(point) {
    const zone = this.pinnedZone;
    const rect = zone && zone.getBoundingClientRect ? zone.getBoundingClientRect() : null;
    const overZone = pointWithinRect(rect, point.x, point.y);
    const value = this.pressOrigin.value;
    let insertIndex = null;

    if (overZone) {
      const nodes = Array.from(zone.querySelectorAll('[data-pin-value]'))
        .filter(node => node.getAttribute('data-pin-value') !== value);
      insertIndex = insertionIndexForPoint(nodes.map(node => node.getBoundingClientRect()), point.x, point.y);
    }

    const snapshot = { value, overZone, insertIndex };
    const previous = this.dragSnapshot;

    this.dragSnapshot = snapshot;

    if (previous && previous.value === value && previous.overZone === overZone && previous.insertIndex === insertIndex) {
      return;
    }

    this.setState({ drag: snapshot });
  }

  commitDrop(snapshot) {
    if (!this.props.onTogglePreferred || !snapshot || !Number.isFinite(snapshot.insertIndex)) {
      return;
    }

    const full = this.preferredValues();
    const visible = this.sections().preferred.map(entry => entry.value);
    const index = preferredDropIndex(full, visible, snapshot.insertIndex, snapshot.value);
    const next = placePreferredEmojiReactionFilter(full, snapshot.value, index);

    if (sameEmojiFilters(next, full)) {
      return;
    }

    this.props.onTogglePreferred(next);
  }

  openPreview(value) {
    if (!this.pressOrigin || this.pressOrigin.value !== value || this.gestureMoved || this.dragStarted) {
      return;
    }

    this.previewShown = true;
    this.setState({ preview: this.presentEntry(this.entryForValue(value)) });
  }

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

  entryForValue(value) {
    const { preferred, remaining } = this.sections();
    const found = preferred.concat(remaining).find(entry => entry.value === value);

    if (found) {
      return found;
    }

    return { value, item: null, missing: false };
  }

  presentEntry(entry) {
    const { value, item } = entry;
    const label = item ? emojiReactionFilterLabel(item) : emojiReactionFilterLabel(value);
    const custom = Boolean(read(item, 'custom'));
    const domain = read(item, 'domain');
    const url = read(item, 'url');
    const staticUrl = read(item, 'static_url');
    const name = read(item, 'name');
    const canRenderImage = Boolean(item) && (!custom || url || staticUrl);

    return {
      value,
      label,
      count: item ? (Number(read(item, 'count')) || 0) : 0,
      missing: Boolean(entry.missing),
      emoji: canRenderImage ? String(name || '') : undefined,
      url: custom ? (url || undefined) : undefined,
      staticUrl: custom ? (staticUrl || undefined) : undefined,
      domain: custom && domain ? domain : undefined,
    };
  }

  renderItem(entry, options = {}) {
    const { intl } = this.props;
    const presented = this.presentEntry(entry);
    const { value, label } = presented;
    const preferred = isPreferredEmojiReaction(this.props.preferredEmojis, value);
    const drag = this.state.drag;

    return (
      <EmojiFilterItem
        key={value}
        value={value}
        label={label}
        count={presented.count}
        selected={this.state.draft.indexOf(value) !== -1}
        hovered={this.state.hovered === value}
        preferred={preferred}
        showPreferredToggle={this.state.editingPinned}
        preferredLabel={intl.formatMessage(preferred ? messages.unpin : messages.pin, { emoji: label })}
        unavailableLabel={presented.missing ? intl.formatMessage(messages.unavailable) : null}
        emoji={presented.emoji}
        url={presented.url}
        staticUrl={presented.staticUrl}
        domain={presented.domain}
        pinned={Boolean(options.pinned)}
        dragging={Boolean(drag && drag.value === value)}
        insertBefore={options.insertBefore === value}
        insertAfter={options.insertAfter === value}
        onToggle={this.handleToggle}
        onHover={this.handleHover}
        onTogglePreferred={this.handleTogglePreferred}
        onPressStart={this.handlePressStart}
        onContextMenu={this.handleContextMenu}
      />
    );
  }

  renderGrid(entries, options = {}) {
    return (
      <div className='emoji-reaction-filter-picker__grid'>
        {entries.map(entry => this.renderItem(entry, options))}
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

  renderPinned(entries) {
    const { intl } = this.props;
    const drag = this.state.drag;
    const visible = entries.map(entry => entry.value).filter(value => !drag || value !== drag.value);
    let insertBefore = null;
    let insertAfter = null;

    if (drag && drag.overZone && Number.isFinite(drag.insertIndex)) {
      if (drag.insertIndex >= visible.length) {
        insertAfter = visible.length > 0 ? visible[visible.length - 1] : null;
      } else {
        insertBefore = visible[drag.insertIndex];
      }
    }

    return (
      <div className='emoji-reaction-filter-picker__pinned'>
        <section
          ref={this.setPinnedZoneRef}
          data-drop-zone='true'
          className={classNames('emoji-reaction-filter-picker__group', 'emoji-reaction-filter-picker__group--pinned', {
            'is-drop-target': Boolean(drag && drag.overZone),
          })}
        >
          <h3 className='emoji-reaction-filter-picker__section-heading'>
            {intl.formatMessage(messages.preferred)}
          </h3>
          {entries.length === 0 ? (
            <div className='emoji-reaction-filter-picker__drop-hint'>
              {intl.formatMessage(messages.dropHint)}
            </div>
          ) : (
            this.renderGrid(entries, {
              pinned: true,
              insertBefore,
              insertAfter,
            })
          )}
        </section>
      </div>
    );
  }

  renderBody(sections, editing) {
    const { intl, isLoading, error } = this.props;
    const items = emojiReactionFilterArray(this.props.catalogItems);
    const { preferred, remaining } = sections;
    const missing = this.missingValues();
    const query = this.state.query.trim();
    const hasContent = preferred.length > 0 || remaining.length > 0 || missing.length > 0;
    const showFrequentHeading = remaining.length > 0 && (editing || this.preferredValues().length > 0);

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
        {!editing && this.renderGroup(messages.preferred, preferred)}
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

  handlePreviewLoad = (event) => {
    const img = event.currentTarget;
    const naturalWidth = img.naturalWidth;
    const naturalHeight = img.naturalHeight;

    if (!naturalWidth || !naturalHeight) {
      return;
    }

    const maxWidth = Math.min(window.innerWidth * 0.9, 520);
    const maxHeight = Math.min(window.innerHeight * 0.65, 520);
    const scale = Math.min(maxWidth / naturalWidth, maxHeight / naturalHeight);

    img.style.width = `${Math.max(1, Math.round(naturalWidth * scale))}px`;
    img.style.height = `${Math.max(1, Math.round(naturalHeight * scale))}px`;
  };

  renderPreview() {
    const { preview } = this.state;

    if (!preview || typeof document === 'undefined' || !document.body) {
      return null;
    }

    return ReactDOM.createPortal(
      <div className='emoji-reaction-filter-preview' data-testid='emoji-reaction-filter-preview'>
        {preview.emoji ? (
          <Emoji
            className='emoji-reaction-filter-preview__glyph'
            emoji={preview.emoji}
            url={preview.url}
            static_url={preview.staticUrl}
            domain={preview.domain}
            hovered={false}
            onLoad={this.handlePreviewLoad}
          />
        ) : (
          <span className='emoji-reaction-filter-preview__fallback'>{preview.label}</span>
        )}
        <div className='emoji-reaction-filter-preview__label'>{preview.label}</div>
      </div>,
      document.body,
    );
  }

  render() {
    const { intl } = this.props;
    const { editingPinned } = this.state;
    const sections = this.sections();
    const count = this.state.draft.length;
    const countLabel = count === 0
      ? intl.formatMessage(messages.noneSelected)
      : intl.formatMessage(messages.selected, { count });

    return (
      <div
        className={classNames('emoji-reaction-filter-picker', { 'is-editing-pinned': editingPinned })}
        role='dialog'
        aria-label={intl.formatMessage(messages.title)}
        onKeyDown={this.handleKeyDown}
        onContextMenu={this.handleContextMenu}
      >
        <div className='emoji-reaction-filter-picker__header'>
          <span className='emoji-reaction-filter-picker__title' title={intl.formatMessage(messages.title)}>{intl.formatMessage(messages.title)}</span>
          <button
            type='button'
            className={classNames('emoji-reaction-filter-picker__edit', { 'is-active': editingPinned })}
            aria-pressed={editingPinned}
            onClick={this.handleToggleEditing}
          >
            {intl.formatMessage(editingPinned ? messages.done : messages.editPinned)}
          </button>
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
        {editingPinned && this.renderPinned(sections.preferred)}
        <div className='emoji-reaction-filter-picker__body'>
          {this.renderBody(sections, editingPinned)}
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
        {this.renderPreview()}
      </div>
    );
  }

}
