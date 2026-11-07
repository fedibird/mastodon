import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import { assetHost } from 'mastodon/utils/config';
import StockEmojiPicker from './stock_emoji_picker';
import { loadDisconnectedEmojiStock } from './emoji_stock_source';
import { emptyEmojiStock, normalizeEmojiStockLoad } from './emoji_stock';
import { loadStandardEmojiPicker } from './standard_emoji_loader';

const messages = defineMessages({
  personal: { id: 'emoji_picker.mode.personal', defaultMessage: 'Personal set' },
  standard: { id: 'emoji_picker.mode.standard', defaultMessage: 'Standard' },
  modes: { id: 'emoji_picker.mode_group', defaultMessage: 'Emoji picker mode' },
  loadingStandard: { id: 'emoji_picker.standard_loading', defaultMessage: 'Loading standard emoji' },
  standardError: { id: 'emoji_picker.standard_error', defaultMessage: 'Could not load the standard emoji picker' },
  retry: { id: 'emoji_picker.stock_retry', defaultMessage: 'Try again' },
});

// Which open shell may move focus. A module that finishes late must not
// pull focus into a picker the user has already left.
let nextEmojiPickerShellId = 0;
let activeEmojiPickerShell = 0;

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
    emojiSize: PropTypes.number,
    perLine: PropTypes.number,
    autoFocus: PropTypes.bool,
    animate: PropTypes.bool,
    theme: PropTypes.string,
  };

  static defaultProps = {
    open: true,
    initialMode: 'personal',
    standardEnabled: true,
    personalEnabled: true,
    onRequestClose: () => {},
    stockSource: loadDisconnectedEmojiStock,
    loadStandardEmojiPicker,
    standardPickerProps: {},
    emojiSize: 22,
    perLine: 8,
    autoFocus: true,
    animate: false,
    theme: 'light',
  };

  constructor(props) {
    super(props);
    this.shellId = ++nextEmojiPickerShellId;
    this.mounted = false;
    this.stockGeneration = 0;
    this.standardGeneration = 0;
    this.stockInFlight = false;
    this.standardInFlight = false;

    if (props.open) {
      activeEmojiPickerShell = this.shellId;
    }

    this.state = {
      mode: this.modeFromProps(props),
      personalQuery: '',
      stockStatus: 'idle',
      stock: emptyEmojiStock(),
      standardStatus: 'idle',
      standardModule: null,
      standardAutoFocus: false,
      suppressFocus: false,
    };
  }

  componentDidMount() {
    this.mounted = true;

    if (this.props.open) {
      this.ensureData();
    }
  }

  componentDidUpdate(prevProps) {
    if (this.props.open && !prevProps.open) {
      this.claimActive();
      this.ensureData();

      if (this.state.suppressFocus || !this.state.standardAutoFocus) {
        this.setState({
          suppressFocus: false,
          standardAutoFocus: this.state.mode === 'standard',
        });
      }
    } else if (!this.props.open && prevProps.open && !this.state.suppressFocus) {
      this.setState({ suppressFocus: true, standardAutoFocus: false });
    }
  }

  componentWillUnmount() {
    this.mounted = false;
    this.stockGeneration += 1;
    this.standardGeneration += 1;

    if (activeEmojiPickerShell === this.shellId) {
      activeEmojiPickerShell = 0;
    }
  }

  modeFromProps(props) {
    const requested = props.initialMode === 'standard' ? 'standard' : 'personal';

    if (requested === 'standard' && props.standardEnabled) {
      return 'standard';
    }

    if (requested === 'personal' && props.personalEnabled) {
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

  ensureData() {
    if (!this.props.open) {
      return;
    }

    if (this.state.mode === 'personal' && this.props.personalEnabled) {
      this.beginStock(false);
    }

    if (this.state.mode === 'standard' && this.props.standardEnabled) {
      this.beginStandard(false);
    }
  }

  beginStock(force) {
    if (!this.props.personalEnabled) {
      return;
    }

    if (this.stockInFlight) {
      return;
    }

    if (!force && this.state.stockStatus === 'ready') {
      return;
    }

    const generation = ++this.stockGeneration;

    this.stockInFlight = true;
    this.setState({ stockStatus: 'loading' });

    Promise.resolve().then(() => this.props.stockSource()).then(result => {
      if (!this.mounted || generation !== this.stockGeneration) {
        return null;
      }

      this.stockInFlight = false;
      const normalized = normalizeEmojiStockLoad(result);

      if (normalized.status === 'error') {
        this.setState({ stockStatus: 'error', stock: emptyEmojiStock() });
        return null;
      }

      // Keep the supplier's object. Search and selection copy what they need.
      this.setState({ stockStatus: 'ready', stock: normalized.stock });
      return null;
    }).catch(error => {
      if (!this.mounted || generation !== this.stockGeneration) {
        return;
      }

      this.stockInFlight = false;
      this.setState({ stockStatus: 'error', stock: emptyEmojiStock(), stockError: error });
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

    Promise.resolve().then(() => this.props.loadStandardEmojiPicker()).then(loaded => {
      if (!this.mounted || generation !== this.standardGeneration) {
        return null;
      }

      this.standardInFlight = false;
      this.setState(prev => ({
        standardStatus: 'ready',
        standardModule: loaded,
        standardAutoFocus: this.props.open && !prev.suppressFocus && activeEmojiPickerShell === this.shellId && prev.mode === 'standard',
      }));
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
    if (!this.props.personalEnabled || this.state.mode === 'personal') {
      return;
    }

    this.claimActive();
    this.setState({ mode: 'personal', suppressFocus: false, standardAutoFocus: false }, () => {
      this.beginStock(false);
    });
  };

  handleStandardMode = () => {
    if (!this.props.standardEnabled || this.state.mode === 'standard') {
      return;
    }

    this.claimActive();
    this.setState({
      mode: 'standard',
      suppressFocus: false,
      standardAutoFocus: this.state.standardStatus === 'ready',
    }, () => {
      this.beginStandard(false);
    });
  };

  handleQueryChange = query => {
    this.setState({ personalQuery: query });
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
    const { intl, personalEnabled, standardEnabled } = this.props;

    if (!personalEnabled || !standardEnabled) {
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

  renderStandard() {
    const { intl, standardPickerProps, autoFocus, emojiSize, perLine, theme } = this.props;
    const { standardStatus, standardModule, standardAutoFocus } = this.state;

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

    if (standardStatus !== 'ready' || !standardModule) {
      return (
        <div className='emoji-picker-shell__loading' style={{ width: 299 }} role='status'>
          {intl.formatMessage(messages.loadingStandard)}
        </div>
      );
    }

    const Picker = standardModule.Picker;
    const focus = Boolean(autoFocus && standardAutoFocus && this.canTakeFocus());

    return (
      <Picker
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
        {...standardPickerProps}
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
    const { personalQuery, stock, stockStatus } = this.state;
    const focus = Boolean(autoFocus && this.canTakeFocus() && stockStatus === 'ready');

    return (
      <StockEmojiPicker
        stock={stock}
        status={stockStatus === 'idle' ? 'loading' : stockStatus}
        query={personalQuery}
        onQueryChange={this.handleQueryChange}
        onPick={this.handlePick}
        onRequestClose={this.requestClose}
        onRetry={this.handleRetryStock}
        emojiSize={emojiSize}
        perLine={perLine}
        autoFocus={focus}
        animate={animate}
        theme={preferredTheme(theme)}
      />
    );
  }

  render() {
    const { open, personalEnabled, standardEnabled } = this.props;
    const { mode } = this.state;

    if (!open || (!personalEnabled && !standardEnabled)) {
      return null;
    }

    return (
      <div className='emoji-picker-shell'>
        {this.renderModeSwitch()}
        {mode === 'standard' ? this.renderStandard() : this.renderPersonal()}
      </div>
    );
  }

}

export default injectIntl(EmojiPickerShell);
