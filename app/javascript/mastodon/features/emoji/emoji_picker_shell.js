import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import { emojiPickerDisableActions, emojiPickerDisablePersonal } from 'mastodon/initial_state';
import { assetHost } from 'mastodon/utils/config';
import StockEmojiPicker from './stock_emoji_picker';
import { getCachedPersonalEmojiStock, loadPersonalEmojiStock, subscribePersonalEmojiStock } from './emoji_stock_source';
import { emptyEmojiStock, normalizeEmojiStockLoad } from './emoji_stock';
import { loadStandardEmojiPicker } from './standard_emoji_loader';
import { markEmojiPickerEscape } from './emoji_picker_escape';

const personalIsEnabled = props => !emojiPickerDisablePersonal && props.personalEnabled;
// The global preference overrides any host that requests picker menus.
const actionsAreEnabled = props => !emojiPickerDisableActions && props.actionsEnabled;

const messages = defineMessages({
  personal: { id: 'emoji_picker.mode.personal', defaultMessage: 'Personal set' },
  standard: { id: 'emoji_picker.mode.standard', defaultMessage: 'Standard' },
  modes: { id: 'emoji_picker.mode_group', defaultMessage: 'Emoji picker mode' },
  edit: { id: 'emoji_picker.edit', defaultMessage: 'Edit' },
  done: { id: 'emoji_picker.done', defaultMessage: 'Done' },
  editGroup: { id: 'emoji_picker.edit_group', defaultMessage: 'Emoji picker editing' },
  loadingStandard: { id: 'emoji_picker.standard_loading', defaultMessage: 'Loading standard emoji' },
  standardError: { id: 'emoji_picker.standard_error', defaultMessage: 'Could not load the standard emoji picker' },
  retry: { id: 'emoji_picker.stock_retry', defaultMessage: 'Try again' },
});

// Which open shell may move focus. Updated when a shell opens and when focus
// actually enters one, so a late standard load cannot steal the field the
// user is typing in.
let nextEmojiPickerShellId = 0;
let activeEmojiPickerShell = 0;

function isImeComposition(event) {
  const native = event && event.nativeEvent;

  return Boolean(
    (event && (event.isComposing || event.keyCode === 229))
    || (native && (native.isComposing || native.keyCode === 229)),
  );
}

// Sprite used only by the standard Nimble picker, matching the existing
// compose and reaction hosts. The personal picker never receives it.
const standardBackgroundImage = () => `${assetHost}/emoji/sheet_15.png`;

function preferredTheme(theme) {
  if (theme === 'dark' || theme === 'light') {
    return theme;
  }

  if (typeof matchMedia !== 'function') {
    return 'light';
  }

  return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

// Shared frame for standard and personal modes. Dropdown placement, modal
// focus traps, and compose/reaction follow-up stay on the host. This frame
// asks the host to close and can restore a focus target the host passed in.
// Escape is handled once here, including the mode switch and standard
// loading state. The personal picker does not send a second close.
class EmojiPickerShell extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    open: PropTypes.bool,
    initialMode: PropTypes.oneOf(['standard', 'personal']),
    standardEnabled: PropTypes.bool,
    personalEnabled: PropTypes.bool,
    onPick: PropTypes.func.isRequired,
    onRequestClose: PropTypes.func,
    returnFocusElement: PropTypes.object,
    stockSource: PropTypes.func,
    loadStandardEmojiPicker: PropTypes.func,
    standardPickerProps: PropTypes.object,
    standardAccessory: PropTypes.node,
    emojiSize: PropTypes.number,
    perLine: PropTypes.number,
    autoFocus: PropTypes.bool,
    animate: PropTypes.bool,
    theme: PropTypes.string,
    onModeChange: PropTypes.func,
    onStandardModule: PropTypes.func,
    deferStandardPicker: PropTypes.bool,
    actionsEnabled: PropTypes.bool,
  };

  static defaultProps = {
    open: true,
    initialMode: 'personal',
    standardEnabled: true,
    personalEnabled: !emojiPickerDisablePersonal,
    onRequestClose: () => {},
    stockSource: loadPersonalEmojiStock,
    loadStandardEmojiPicker,
    standardPickerProps: {},
    emojiSize: 22,
    perLine: 8,
    autoFocus: true,
    animate: false,
    theme: 'light',
    actionsEnabled: true,
  };

  constructor(props) {
    super(props);
    this.shellId = ++nextEmojiPickerShellId;
    this.mounted = false;
    this.stockGeneration = 0;
    this.standardGeneration = 0;
    this.stockInFlight = false;
    this.standardInFlight = false;
    this.pendingStandardSearch = undefined;
    const cachedStock = personalIsEnabled(props) && props.stockSource === loadPersonalEmojiStock ? getCachedPersonalEmojiStock() : null;

    if (props.open) {
      activeEmojiPickerShell = this.shellId;
    }

    this.state = {
      shellId: this.shellId,
      wasOpen: props.open,
      mode: this.modeFromProps(props),
      // Shared across standard/personal; resets whenever the shell reopens.
      editMode: false,
      searchQuery: '',
      stockStatus: cachedStock ? 'ready' : 'idle',
      stock: cachedStock ? cachedStock.stock : emptyEmojiStock(),
      standardStatus: 'idle',
      standardModule: null,
      standardAutoFocus: false,
      suppressFocus: false,
    };
  }

  // The standard picker reads autoFocus only when it mounts. Reopening has
  // to set that flag before the first open render, not in componentDidUpdate.
  static getDerivedStateFromProps(nextProps, state) {
    if (nextProps.open && state.wasOpen === false) {
      activeEmojiPickerShell = state.shellId;

      return {
        wasOpen: true,
        suppressFocus: false,
        standardAutoFocus: state.mode === 'standard',
        editMode: false,
      };
    }

    if (!nextProps.open && state.wasOpen !== false) {
      return {
        wasOpen: false,
        suppressFocus: true,
        standardAutoFocus: false,
        editMode: false,
      };
    }

    return null;
  }

  componentDidMount() {
    this.mounted = true;
    this.bindStockSource();

    if (this.props.open) {
      this.ensureData(this.props.stockSource === loadPersonalEmojiStock);
      this.emitMode(this.state.mode);
    }
  }

  standardSearchInput() {
    return this.node && this.node.querySelector('.emoji-picker-shell__standard .emoji-mart-search input');
  }

  getSnapshotBeforeUpdate(prevProps) {
    const previous = (prevProps.standardPickerProps || {}).pickerRevision || 'standard';
    const next = (this.props.standardPickerProps || {}).pickerRevision || 'standard';

    if ((previous === next && prevProps.emojiSize === this.props.emojiSize && prevProps.perLine === this.props.perLine) || !this.node) {
      return null;
    }

    const input = this.standardSearchInput();

    if (!input) {
      return null;
    }

    return {
      value: input.value,
      focused: document.activeElement === input,
    };
  }

  componentDidUpdate(prevProps, _prevState, snapshot) {
    this.restoreStandardSearch(snapshot);
    this.applyPendingStandardSearch();

    if (prevProps.stockSource !== this.props.stockSource) {
      this.bindStockSource();
      this.handleStockChange(null);
    }

    if (this.props.open && !prevProps.open) {
      this.claimActive();
      this.ensureData(this.props.stockSource === loadPersonalEmojiStock);
      this.emitMode(this.state.mode);
    }
  }

  restoreStandardSearch(snapshot) {
    if (!snapshot || !this.node) {
      return;
    }

    const input = this.standardSearchInput();

    if (!input) {
      return;
    }

    if (snapshot.value) {
      input.value = snapshot.value;
      this.dispatchSearchInput(input);
      // Nimble paints the remaining categories after this search. A search
      // only hides categories that already exist, so repeat it once they mount.
      this.syncSearchCategories(input);
    }

    if (snapshot.focused) {
      input.focus();
    }
  }

  // Nimble manages its own search state, so replay the personal query after
  // the standard picker mounts (including an asynchronously loaded module).
  // Do not load the standard dataset just to keep the input text.
  applyPendingStandardSearch() {
    if (this.state.mode !== 'standard' || this.pendingStandardSearch === undefined) {
      return;
    }

    const input = this.standardSearchInput();

    if (!input) {
      return;
    }

    const query = this.pendingStandardSearch;
    this.pendingStandardSearch = undefined;

    if (input.value === query) {
      return;
    }

    input.value = query;
    this.dispatchSearchInput(input);

    if (query) {
      this.syncSearchCategories(input);
    }
  }

  // React 16 records a value assignment in the tracker. Repeating that value
  // through an input event does not reach Nimble's onChange unless the
  // tracker is cleared first.
  dispatchSearchInput(input) {
    if (input._valueTracker) {
      input._valueTracker.setValue('');
    }

    input.dispatchEvent(new Event('input', { bubbles: true }));
  }

  stopSearchCategorySync() {
    if (this.searchCategoryObserver) {
      this.searchCategoryObserver.disconnect();
      this.searchCategoryObserver = null;
    }

    clearTimeout(this.searchCategoryTimer);
    this.searchCategoryTimer = null;
    this.searchCategoryGeneration = (this.searchCategoryGeneration || 0) + 1;
  }

  hideCategoriesOutsideSearch(scroll) {
    const sections = scroll.querySelectorAll('.emoji-mart-category');

    for (let i = 0; i < sections.length; i += 1) {
      const label = sections[i].querySelector('.emoji-mart-category-label');
      const name = label && label.getAttribute('data-name');

      if (name && name !== 'Search') {
        sections[i].style.display = 'none';
      }
    }
  }

  syncSearchCategories(input) {
    this.stopSearchCategorySync();

    const scroll = this.node && this.node.querySelector('.emoji-mart-scroll');
    const generation = this.searchCategoryGeneration;

    if (!scroll) {
      return;
    }

    const apply = () => {
      if (generation !== this.searchCategoryGeneration || !input.isConnected || input.value === '') {
        return;
      }

      this.hideCategoriesOutsideSearch(scroll);
      this.dispatchSearchInput(input);
    };

    if (typeof MutationObserver === 'function') {
      this.searchCategoryObserver = new MutationObserver(apply);
      this.searchCategoryObserver.observe(scroll, { childList: true });
    }

    // The staged categories are added on a 60ms timer that started before
    // this update. Apply once more after that wave, then stop watching.
    this.searchCategoryTimer = setTimeout(() => {
      apply();

      if (generation === this.searchCategoryGeneration) {
        this.stopSearchCategorySync();
      }
    }, 80);
  }

  componentWillUnmount() {
    this.mounted = false;
    this.stockGeneration += 1;
    this.standardGeneration += 1;
    this.stopSearchCategorySync();
    this.detachFocusListener();
    if (this.unsubscribeStock) {
      this.unsubscribeStock();
    }

    if (activeEmojiPickerShell === this.shellId) {
      activeEmojiPickerShell = 0;
    }
  }

  bindStockSource() {
    if (this.unsubscribeStock) {
      this.unsubscribeStock();
    }

    this.unsubscribeStock = personalIsEnabled(this.props) && this.props.stockSource === loadPersonalEmojiStock
      ? subscribePersonalEmojiStock(this.handleStockChange)
      : null;
  }

  handleStockChange = result => {
    if (!this.mounted) {
      return;
    }

    this.stockGeneration += 1;
    this.stockInFlight = false;
    this.setState({
      stockStatus: result ? 'ready' : 'idle',
      stock: result ? result.stock : emptyEmojiStock(),
    }, () => {
      if (!result && this.props.open && this.state.mode === 'personal') {
        this.beginStock(true);
      }
    });
  };

  setNode = node => {
    this.detachFocusListener();
    this.node = node;

    if (node) {
      node.addEventListener('focusin', this.handleFocusIn);
    }
  };

  detachFocusListener() {
    if (this.node) {
      this.node.removeEventListener('focusin', this.handleFocusIn);
    }
  }

  handleFocusIn = () => {
    if (this.props.open) {
      this.claimActive();
    }
  };

  handleKeyDown = event => {
    if (this.props.open) {
      this.claimActive();
    }

    if (event.key !== 'Escape' || isImeComposition(event)) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    if (event.nativeEvent && typeof event.nativeEvent.stopImmediatePropagation === 'function') {
      event.nativeEvent.stopImmediatePropagation();
    }

    // keydown does not stop the later window keyup ModalRoot uses.
    markEmojiPickerEscape();
    this.requestClose(event);
  };

  emitMode(mode) {
    if (this.props.onModeChange) {
      this.props.onModeChange(mode);
    }
  }

  modeFromProps(props) {
    const requested = props.initialMode === 'standard' ? 'standard' : 'personal';

    if (requested === 'standard' && props.standardEnabled) {
      return 'standard';
    }

    if (requested === 'personal' && personalIsEnabled(props)) {
      return 'personal';
    }

    if (props.standardEnabled) {
      return 'standard';
    }

    return 'personal';
  }

  claimActive() {
    activeEmojiPickerShell = this.shellId;
  }

  canTakeFocus() {
    return this.props.open && !this.state.suppressFocus && activeEmojiPickerShell === this.shellId;
  }

  ensureData(forceStock = false) {
    if (!this.props.open) {
      return;
    }

    if (this.state.mode === 'personal' && personalIsEnabled(this.props)) {
      this.beginStock(forceStock);
    }

    if (this.state.mode === 'standard' && this.props.standardEnabled) {
      this.beginStandard(false);
    }
  }

  beginStock(force) {
    if (!personalIsEnabled(this.props) || this.stockInFlight) {
      return;
    }

    // The application may have preloaded stock, or another picker may have
    // fetched it while this one was in standard mode. Paint that object now
    // and keep it visible while ETag revalidation completes.
    const warm = this.props.stockSource === loadPersonalEmojiStock ? getCachedPersonalEmojiStock() : null;
    const hasReadyStock = this.state.stockStatus === 'ready' || Boolean(warm);

    if (warm && (this.state.stockStatus !== 'ready' || this.state.stock !== warm.stock)) {
      this.setState({ stockStatus: 'ready', stock: warm.stock });
    }

    if (!force && hasReadyStock) {
      return;
    }

    const generation = ++this.stockGeneration;

    this.stockInFlight = true;
    if (!hasReadyStock) {
      this.setState({ stockStatus: 'loading' });
    }

    Promise.resolve().then(() => this.props.stockSource()).then(result => {
      if (!this.mounted || generation !== this.stockGeneration) {
        return null;
      }

      this.stockInFlight = false;
      const normalized = normalizeEmojiStockLoad(result);

      if (normalized.status === 'error') {
        if (!hasReadyStock) {
          this.setState({ stockStatus: 'error', stock: emptyEmojiStock() });
        }
        return null;
      }

      // A 304 response keeps the same stock object, so it needs no rerender.
      this.setState(prev => prev.stockStatus === 'ready' && prev.stock === normalized.stock
        ? null : { stockStatus: 'ready', stock: normalized.stock });
      return null;
    }).catch(error => {
      if (!this.mounted || generation !== this.stockGeneration) {
        return;
      }

      this.stockInFlight = false;
      if (!hasReadyStock) {
        this.setState({ stockStatus: 'error', stock: emptyEmojiStock(), stockError: error });
      }
    });
  }

  beginStandard(force) {
    if (!this.props.standardEnabled) {
      return;
    }

    if (this.standardInFlight) {
      return;
    }

    if (!force && this.state.standardStatus === 'ready' && this.state.standardModule) {
      return;
    }

    const generation = ++this.standardGeneration;

    this.standardInFlight = true;
    this.setState({ standardStatus: 'loading', standardAutoFocus: false });

    let loading;

    try {
      loading = this.props.loadStandardEmojiPicker();
    } catch (error) {
      loading = Promise.reject(error);
    }

    Promise.resolve(loading).then(loaded => {
      if (!this.mounted || generation !== this.standardGeneration) {
        return null;
      }

      this.standardInFlight = false;
      this.setState(prev => ({
        standardStatus: 'ready',
        standardModule: loaded,
        standardAutoFocus: this.props.open && !prev.suppressFocus && activeEmojiPickerShell === this.shellId && prev.mode === 'standard',
      }));

      if (this.props.onStandardModule) {
        this.props.onStandardModule(loaded);
      }

      return null;
    }).catch(() => {
      if (!this.mounted || generation !== this.standardGeneration) {
        return;
      }

      this.standardInFlight = false;
      this.setState({ standardStatus: 'error', standardAutoFocus: false });
    });
  }

  handlePersonalMode = () => {
    if (!personalIsEnabled(this.props) || this.state.mode === 'personal') {
      return;
    }

    this.claimActive();
    // The standard search input belongs to Nimble; capture it before its
    // subtree unmounts. This also picks up searches cleared by Nimble itself.
    const standardSearch = this.standardSearchInput();
    this.pendingStandardSearch = undefined;
    this.stopSearchCategorySync();
    this.setState({
      mode: 'personal',
      searchQuery: standardSearch ? standardSearch.value : this.state.searchQuery,
      suppressFocus: false,
      standardAutoFocus: false,
    }, () => {
      this.beginStock(this.props.stockSource === loadPersonalEmojiStock);
      this.emitMode('personal');
    });
  };

  handleStandardMode = () => {
    if (!this.props.standardEnabled || this.state.mode === 'standard') {
      return;
    }

    this.claimActive();
    this.pendingStandardSearch = this.state.searchQuery;
    this.setState({
      mode: 'standard',
      suppressFocus: false,
      standardAutoFocus: this.state.standardStatus === 'ready',
    }, () => {
      this.beginStandard(false);
      this.emitMode('standard');
    });
  };

  handleQueryChange = query => {
    this.setState({ searchQuery: query });
  };

  handleToggleEditMode = () => {
    this.setState(state => ({ editMode: !state.editMode }));
  };

  handleRetryStock = () => {
    this.stockInFlight = false;
    this.beginStock(true);
  };

  handleRetryStandard = () => {
    this.standardInFlight = false;
    this.beginStandard(true);
  };

  requestClose = event => {
    this.setState({ suppressFocus: true, standardAutoFocus: false });
    this.props.onRequestClose(event);

    const target = this.props.returnFocusElement;

    if (target && typeof target.focus === 'function') {
      target.focus({ preventScroll: true });
    }
  };

  handlePick = (payload, event) => {
    this.props.onPick(payload, event);

    if (!event || !(event.ctrlKey || event.metaKey)) {
      this.requestClose(event);
    }
  };

  renderModeSwitch() {
    const { intl, standardEnabled } = this.props;

    if (!personalIsEnabled(this.props) || !standardEnabled) {
      return null;
    }

    const { mode } = this.state;

    return (
      <div className='emoji-mart-bar emoji-picker-shell__modes' role='group' aria-label={intl.formatMessage(messages.modes)}>
        <div className='emoji-mart-anchors'>
          <button
            type='button'
            className={classNames('emoji-mart-anchor', { 'emoji-mart-anchor-selected': mode === 'personal' })}
            aria-pressed={mode === 'personal'}
            onClick={this.handlePersonalMode}
          >
            {intl.formatMessage(messages.personal)}
          </button>
          <button
            type='button'
            className={classNames('emoji-mart-anchor', { 'emoji-mart-anchor-selected': mode === 'standard' })}
            aria-pressed={mode === 'standard'}
            onClick={this.handleStandardMode}
          >
            {intl.formatMessage(messages.standard)}
          </button>
        </div>
      </div>
    );
  }

  renderEditToggle() {
    const { intl } = this.props;

    if (!actionsAreEnabled(this.props)) {
      return null;
    }
    const { editMode } = this.state;

    return (
      <div className='emoji-mart-bar emoji-picker-shell__edit' role='group' aria-label={intl.formatMessage(messages.editGroup)}>
        <button
          type='button'
          className={classNames('emoji-picker-shell__edit-toggle', { 'emoji-picker-shell__edit-toggle--active': editMode })}
          aria-pressed={editMode}
          onClick={this.handleToggleEditMode}
        >
          {intl.formatMessage(editMode ? messages.done : messages.edit)}
        </button>
      </div>
    );
  }

  renderStandard() {
    const { intl, standardPickerProps, autoFocus, emojiSize, perLine, theme } = this.props;
    const { standardStatus, standardModule, standardAutoFocus, editMode } = this.state;
    const effectiveEditMode = actionsAreEnabled(this.props) ? editMode : false;

    if (standardStatus === 'error') {
      return (
        <div className='emoji-mart-no-results' role='status'>
          <div>{intl.formatMessage(messages.standardError)}</div>
          <button type='button' onClick={this.handleRetryStandard}>
            {intl.formatMessage(messages.retry)}
          </button>
        </div>
      );
    }

    if (this.props.deferStandardPicker || standardStatus !== 'ready' || !standardModule) {
      return (
        <div className='emoji-picker-shell__loading' style={{ width: 299 }} role='status'>
          {intl.formatMessage(messages.loadingStandard)}
        </div>
      );
    }

    const Picker = standardModule.Picker;
    const focus = Boolean(autoFocus && standardAutoFocus && this.canTakeFocus());
    const { pickerRevision, ...pickerProps } = standardPickerProps;

    // Nimble builds custom categories in its constructor and ignores later
    // custom/include updates. A new revision remounts it so a catalog that
    // arrives after the module is ready still appears.
    return (
      <Picker
        key={`${pickerRevision || 'standard'}:${emojiSize}:${perLine}`}
        sheetColumns={62}
        sheetRows={62}
        sheetSize={32}
        custom={[]}
        color=''
        emoji=''
        set='twitter'
        title={intl.formatMessage(messages.standard)}
        showPreview={false}
        showSkinTones={false}
        backgroundImageFn={standardBackgroundImage}
        {...pickerProps}
        editMode={effectiveEditMode}
        actionsEnabled={actionsAreEnabled(this.props)}
        perLine={perLine}
        emojiSize={emojiSize}
        theme={preferredTheme(theme)}
        autoFocus={focus}
        onClick={this.handlePick}
      />
    );
  }

  renderPersonal() {
    const { animate, autoFocus, emojiSize, perLine, theme } = this.props;
    const { searchQuery, stock, stockStatus, editMode } = this.state;
    const effectiveEditMode = actionsAreEnabled(this.props) ? editMode : false;
    const focus = Boolean(autoFocus && this.canTakeFocus() && stockStatus === 'ready');

    return (
      <StockEmojiPicker
        stock={stock}
        status={stockStatus === 'idle' ? 'loading' : stockStatus}
        query={searchQuery}
        onQueryChange={this.handleQueryChange}
        onPick={this.handlePick}
        onRequestClose={this.requestClose}
        onRetry={this.handleRetryStock}
        emojiSize={emojiSize}
        perLine={perLine}
        autoFocus={focus}
        animate={animate}
        theme={preferredTheme(theme)}
        editMode={effectiveEditMode}
        actionsEnabled={actionsAreEnabled(this.props)}
      />
    );
  }

  render() {
    const { open, standardEnabled } = this.props;
    const { mode } = this.state;

    if (!open || (!personalIsEnabled(this.props) && !standardEnabled)) {
      return null;
    }

    return (
      <div className={classNames('emoji-picker-shell', { 'emoji-picker-shell--dark': preferredTheme(this.props.theme) === 'dark' })} ref={this.setNode} onKeyDown={this.handleKeyDown}>
        <div className='emoji-picker-shell__chrome'>
          {this.renderModeSwitch()}
          {this.renderEditToggle()}
        </div>
        {mode === 'standard' ? (
          <div className='emoji-picker-shell__standard'>
            {this.renderStandard()}
            {this.props.standardAccessory}
          </div>
        ) : this.renderPersonal()}
      </div>
    );
  }

}

export default injectIntl(EmojiPickerShell);
