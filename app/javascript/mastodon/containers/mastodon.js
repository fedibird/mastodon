import React from 'react';
import { createPortal } from 'react-dom';
import { Provider } from 'react-redux';
import PropTypes from 'prop-types';
import configureStore from '../store/configureStore';
import { BrowserRouter, Route } from 'react-router-dom';
import { ScrollContext } from 'react-router-scroll-4';
import UI from '../features/ui';
import { settingsReturnScroll, settleSettingsReturnScroll } from '../features/embedded_rails_settings/navigation';
import { fetchCircles } from '../actions/circles';
import { ensureCustomEmojis } from '../actions/custom_emojis';
import { preloadEmojiPickersIfNeeded } from '../features/emoji/emoji_picker_preferences';
import { hydrateStore } from '../actions/store';
import { startMastodonSubscriptions } from './mastodon_subscriptions';
import { IntlProvider, addLocaleData, FormattedMessage } from 'react-intl';
import { syncEmojiMutes, invalidateEmojiMuteAsyncWork, EMOJI_MUTES_RESET } from '../actions/emoji_mutes';
import { classifyEmojiMuteFetchError } from '../features/emoji/emoji_mute_fetch_error';
import { resetEmojiMuteSession } from '../features/emoji/emoji_mute_store';
import { emojiMuteBypassEnabled, requestEmojiMuteBypass, clearEmojiMuteBypass } from '../features/emoji/emoji_mute_boot_bypass';
import { setEmojiActionsOverlayPrivacyContainer } from '../features/emoji/emoji_actions/overlay_root';
import { getLocale } from '../locales';
import initialState from '../initial_state';
import ErrorBoundary from '../components/error_boundary';

const { localeData, messages } = getLocale();
addLocaleData(localeData);

export const store = configureStore();
const hydrateAction = hydrateStore(initialState);

store.dispatch(hydrateAction);
store.dispatch(fetchCircles());
// Share the catalog request/result with the first standard picker open.
// Preloads are deliberately not awaited before mounting the WebUI.
preloadEmojiPickersIfNeeded(undefined, undefined, () => store.dispatch(ensureCustomEmojis()));

// The rules are scoped to the authenticated viewer. The bootstrap credential
// cannot be switched in-place: changing accounts requires a fresh application
// initialization so every cached status and mute projection belongs to one
// viewer.
const signedIn = !!(initialState?.meta?.me || initialState?.meta?.access_token);
// A failed network read can be repeated. Ignore clicks until this quiet
// period has elapsed so a held button cannot queue a burst of GETs.
const EMOJI_MUTE_RETRY_COOLDOWN_MS = 1000;
const EMOJI_MUTE_BOOT_RECOVERY_DELAY_MS = 2500;
const sessionMatches = state => {
  if (!state || typeof state.getIn !== 'function') {
    return true;
  }

  return String(state.getIn(['meta', 'me']) || '') === String(initialState?.meta?.me || '') &&
    String(state.getIn(['meta', 'access_token']) || '') === String(initialState?.meta?.access_token || '');
};


export default class Mastodon extends React.PureComponent {

  static propTypes = {
    locale: PropTypes.string.isRequired,
  };

  state = {
    emojiMuteBoot: signedIn ? 'loading' : 'ready',
    emojiMuteFailure: null,
    showSlowStart: false,
    bypassStorageError: false,
  };

  // Consecutive Redux actions may be batched before React commits setState.
  // Compare the requested phase as well as the committed one so a stale
  // action always supersedes an earlier ready action in the same batch.
  requestedBootPhase = signedIn ? 'loading' : 'ready';

  // The portal target is never changed or unmounted during a mute revision.
  // Instead we detach *that same DOM node* from the visible document. This
  // removes the unverified images/alt/aria without throwing away UI/Router,
  // compose drafts, masonry measurements, or React component instances.
  uiPortalRoot = document.createElement('div');
  uiInitialized = false;

  setUiPortalHost = node => {
    this.uiPortalHost = node;
  };

  detachUiPortal = () => {
    // Cancel any ready transition that has been queued while the rules were
    // changing. The source DOM must never re-enter the document afterward.
    this.uiRevealGeneration = (this.uiRevealGeneration || 0) + 1;

    if (this.uiPortalRoot.parentNode !== this.uiPortalHost || !this.uiPortalHost) {
      return;
    }

    const scrolling = [
      ...this.uiPortalRoot.querySelectorAll('.scrollable, .modal-root__modal'),
      document.scrollingElement,
    ].filter(Boolean);

    this.savedUiScroll = scrolling.map(node => ({
      node,
      top: node.scrollTop,
      left: node.scrollLeft,
    }));

    const active = document.activeElement;
    this.savedUiFocus = active && this.uiPortalRoot.contains(active) ? active : null;

    // Leave focus in the visible document. A detached menu or dialog must
    // not remain the active element, or Tab never reaches the retry controls.
    if (this.savedUiFocus && typeof this.savedUiFocus.blur === 'function') {
      this.savedUiFocus.blur();
    }

    this.uiPortalHost.removeChild(this.uiPortalRoot);
  };

  attachUiPortal = () => {
    if (!this.uiPortalHost || !this.uiInitialized || this.sessionChanged) {
      return;
    }

    if (this.uiPortalRoot.parentNode !== this.uiPortalHost) {
      this.uiPortalHost.appendChild(this.uiPortalRoot);
    }

    if (this.savedUiScroll) {
      this.savedUiScroll.forEach(({ node, top, left }) => {
        if (node.isConnected || node === document.scrollingElement) {
          node.scrollTop = top;
          node.scrollLeft = left;
        }
      });
      this.savedUiScroll = null;
    }

    if (this.savedUiFocus && this.savedUiFocus.isConnected && document.activeElement === document.body) {
      this.savedUiFocus.focus();
    }
    this.savedUiFocus = null;
  };

  scheduleUiPortalRestore = () => {
    const generation = this.uiRevealGeneration || 0;

    // The Mastodon store subscription runs before the nested display
    // subscriptions. Wait until the current Redux dispatch has finished
    // updating their projected HTML/ARIA before making it visible again.
    Promise.resolve().then(() => {
      if (generation !== (this.uiRevealGeneration || 0) || !this.mounted || this.sessionChanged ||
          this.state.emojiMuteBoot !== 'ready' || this.requestedBootPhase !== 'ready' ||
          store.getState().getIn(['emojiMutes', 'phase']) !== 'ready') {
        return null;
      }

      this.attachUiPortal();
      return null;
    }).catch(error => {
      if (!this.mounted || this.sessionChanged) {
        return null;
      }

      throw error;
    });
  };

  startSlowStartTimer = () => {
    this.stopSlowStartTimer();
    this.setState({ showSlowStart: false, bypassStorageError: false });
    this.slowStartTimer = setTimeout(() => {
      this.slowStartTimer = null;
      if (this.mounted && this.requestedBootPhase === 'loading') {
        this.setState({ showSlowStart: true });
      }
    }, EMOJI_MUTE_BOOT_RECOVERY_DELAY_MS);
  };

  stopSlowStartTimer = () => {
    if (this.slowStartTimer !== null && this.slowStartTimer !== undefined) {
      clearTimeout(this.slowStartTimer);
      this.slowStartTimer = null;
    }
  };

  componentDidMount() {
    this.mounted = true;
    this.uiPortalRoot.className = 'emoji-mutes-privacy-portal';
    setEmojiActionsOverlayPrivacyContainer(this.uiPortalRoot);
    this.unsubscribeEmojiMutes = store.subscribe(this.observeEmojiMuteState);

    // A guest does not have a per-user mute document to fetch.
    if (signedIn) {
      this.bootstrapEmojiMutes();
    } else {
      this.uiInitialized = true;
      this.uiPortalRoot.style.display = 'contents';
      this.attachUiPortal();
      this.forceUpdate();
      this.startSubscriptions();
    }
  }

  componentWillUnmount () {
    this.stopSlowStartTimer();
    this.mounted = false;
    this.bootstrapGeneration = (this.bootstrapGeneration || 0) + 1;
    this.detachUiPortal();
    setEmojiActionsOverlayPrivacyContainer(null);

    if (this.unsubscribeEmojiMutes) {
      this.unsubscribeEmojiMutes();
      this.unsubscribeEmojiMutes = null;
    }

    if (this.disconnect) {
      this.disconnect();
      this.disconnect = null;
    }

    // The same JS runtime must never carry a signed-in viewer's rules into a
    // later shell. Late GET promises are invalidated by the session counter.
    invalidateEmojiMuteAsyncWork();
    resetEmojiMuteSession();
    store.dispatch({ type: EMOJI_MUTES_RESET });
  }

  startSubscriptions = () => {
    if (!this.disconnect && this.mounted && !this.sessionChanged) {
      this.disconnect = startMastodonSubscriptions(store);
    }
  };

  // A newer streaming revision means the currently rendered HTML may expose
  // a newly muted emoji. Remove the WebUI (including images and aria labels)
  // rather than merely covering it with CSS. Keep the Redux data intact.
  observeEmojiMuteState = () => {
    if (!this.mounted || this.sessionChanged) {
      return;
    }

    const state = store.getState();

    if (!sessionMatches(state)) {
      this.stopSlowStartTimer();
      this.detachUiPortal();
      setEmojiActionsOverlayPrivacyContainer(null);
      this.uiInitialized = false;
      this.sessionChanged = true;
      this.requestedBootPhase = 'session-changed';
      this.bootstrapGeneration = (this.bootstrapGeneration || 0) + 1;
      this.setState({ emojiMuteBoot: 'session-changed' }, () => {
        if (this.disconnect) {
          this.disconnect();
          this.disconnect = null;
        }

        invalidateEmojiMuteAsyncWork();
        resetEmojiMuteSession();
        store.dispatch({ type: EMOJI_MUTES_RESET });
      });
      return;
    }

    if (!signedIn || !this.bootstrapComplete) {
      return;
    }

    const phase = state.getIn(['emojiMutes', 'phase']);
    let next = 'loading';

    if (phase === 'ready') {
      next = 'ready';
    } else if (phase === 'error') {
      next = 'error';
    }

    if (next !== this.requestedBootPhase) {
      this.requestedBootPhase = next;
      if (next === 'loading') {
        this.startSlowStartTimer();
      } else {
        this.stopSlowStartTimer();
      }
      if (next !== 'ready') {
        // Detach synchronously when the Redux revision changes, before any
        // existing display subscription can expose unverified emoji content.
        this.detachUiPortal();
      }

      this.setState({
        emojiMuteBoot: next,
        emojiMuteFailure: next === 'error' ? (state.getIn(['emojiMutes', 'failure']) || 'unavailable') : null,
      }, () => {
        if (next === 'ready' && this.mounted && !this.sessionChanged) {
          this.scheduleUiPortalRestore();
        }
      });
    }
  };

  bootstrapEmojiMutes = () => {
    if (this.emojiMuteRequestInFlight || Date.now() < (this.retryReadyAt || 0)) {
      return;
    }

    const generation = (this.bootstrapGeneration || 0) + 1;
    this.bootstrapGeneration = generation;
    this.emojiMuteRequestInFlight = true;
    this.retryReadyAt = 0;
    this.requestedBootPhase = 'loading';
    this.startSlowStartTimer();
    this.setState({ emojiMuteBoot: 'loading', emojiMuteFailure: null });

    // Skip the status and notification refresh only before the first UI
    // mount. A retry while that UI is detached still has withheld reactions
    // and a notification list to restore, without mounting the columns again.
    store.dispatch(syncEmojiMutes({ bootstrap: !this.uiInitialized })).then(() => {
      if (generation !== this.bootstrapGeneration) {
        return;
      }

      this.emojiMuteRequestInFlight = false;

      if (!this.mounted || this.sessionChanged) {
        return;
      }

      this.bootstrapComplete = true;
      // A stale server answer can resolve without applying a document. That
      // is not permission to reveal the hydrated timeline.
      const phase = store.getState().getIn(['emojiMutes', 'phase']);
      if (phase !== 'ready') {
        const failure = store.getState().getIn(['emojiMutes', 'failure']) || 'unavailable';
        this.requestedBootPhase = 'error';
        if (failure === 'unavailable') {
          this.retryReadyAt = Date.now() + EMOJI_MUTE_RETRY_COOLDOWN_MS;
        }
        this.stopSlowStartTimer();
        this.setState({ emojiMuteBoot: 'error', emojiMuteFailure: failure });
        return;
      }

      const initialMount = !this.uiInitialized;
      this.uiInitialized = true;
      this.uiPortalRoot.style.display = 'contents';
      if (initialMount) {
        // An empty root is safe to attach before the first UI mount; this
        // ensures componentDidMount sees real geometry.
        this.attachUiPortal();
      }

      this.requestedBootPhase = 'ready';
      this.stopSlowStartTimer();
      this.setState({ emojiMuteBoot: 'ready', emojiMuteFailure: null }, () => {
        if (!initialMount) {
          // An existing UI holds old HTML. It must remain detached until
          // the fresh Redux document has propagated to its display nodes.
          this.scheduleUiPortalRestore();
        }
        this.startSubscriptions();
      });
    }).catch(error => {
      if (generation !== this.bootstrapGeneration) {
        return;
      }

      this.emojiMuteRequestInFlight = false;

      if (!this.mounted || this.sessionChanged) {
        return;
      }

      const failure = classifyEmojiMuteFetchError(error);
      this.bootstrapComplete = true;
      this.requestedBootPhase = 'error';

      if (failure === 'unavailable') {
        this.retryReadyAt = Date.now() + EMOJI_MUTE_RETRY_COOLDOWN_MS;
      }

      this.stopSlowStartTimer();
      this.setState({ emojiMuteBoot: 'error', emojiMuteFailure: failure });
    });
  };

  shouldUpdateScroll (prevRouterProps, { location }) {
    const settingsPosition = settingsReturnScroll(prevRouterProps?.location, location);
    if (settingsPosition) {
      settleSettingsReturnScroll(location, settingsPosition);
      return settingsPosition;
    }
    return !(location.state?.mastodonModalKey && location.state?.mastodonModalKey !== prevRouterProps?.location?.state?.mastodonModalKey);
  }

  reloadPage = () => {
    window.location.reload();
  };

  startWithoutEmojiMutes = () => {
    // A reload starts with an empty viewer projection; never reveal a partially
    // processed document while the previous request is still in flight.
    if (requestEmojiMuteBypass()) {
      this.reloadPage();
    } else {
      this.setState({ bypassStorageError: true });
    }
  };

  restoreEmojiMutes = () => {
    if (clearEmojiMuteBypass()) {
      this.reloadPage();
    }
  };

  render () {
    const { locale } = this.props;

    const boot = this.state.emojiMuteBoot;
    let bootContent;

    if (boot === 'loading') {
      bootContent = this.state.showSlowStart
        ? <p><FormattedMessage id='emoji_mutes.bootstrap_preparing' defaultMessage='Preparing the interface…' /></p>
        : null;
    } else if (boot === 'session-changed') {
      bootContent = (
        <React.Fragment>
          <p><FormattedMessage id='emoji_mutes.session_changed' defaultMessage='Your account changed. Reload to protect your emoji mute settings.' /></p>
          <button type='button' onClick={this.reloadPage}>
            <FormattedMessage id='emoji_mutes.session_reload' defaultMessage='Reload the page' />
          </button>
        </React.Fragment>
      );
    } else if (this.state.emojiMuteFailure === 'unauthorized') {
      bootContent = (
        <React.Fragment>
          <p><FormattedMessage id='emoji_mutes.bootstrap_unauthorized' defaultMessage='Your session expired. Reload and sign in again. Other features may remain unavailable if you start without emoji muting.' /></p>
          <button type='button' onClick={this.reloadPage}>
            <FormattedMessage id='emoji_mutes.bootstrap_sign_in' defaultMessage='Reload and sign in' />
          </button>
        </React.Fragment>
      );
    } else if (this.state.emojiMuteFailure === 'forbidden') {
      bootContent = (
        <p><FormattedMessage id='emoji_mutes.bootstrap_forbidden' defaultMessage='This account cannot read emoji mute settings. Normal startup cannot continue.' /></p>
      );
    } else {
      bootContent = (
        <React.Fragment>
          <p><FormattedMessage id='emoji_mutes.bootstrap_error' defaultMessage='Emoji mute settings could not be verified. Retry loading or start without emoji muting.' /></p>
          <button type='button' onClick={this.bootstrapEmojiMutes}>
            <FormattedMessage id='emoji_mutes.bootstrap_retry' defaultMessage='Retry loading settings' />
          </button>
        </React.Fragment>
      );
    }

    const showBootPanel = boot !== 'ready' && (boot !== 'loading' || this.state.showSlowStart);

    const ui = this.uiInitialized && createPortal(
      <BrowserRouter basename='/web'>
        <ScrollContext shouldUpdateScroll={this.shouldUpdateScroll}>
          <Route path='/' component={UI} />
        </ScrollContext>
      </BrowserRouter>,
      this.uiPortalRoot,
    );

    return (
      <IntlProvider locale={locale} messages={messages}>
        <Provider store={store}>
          <ErrorBoundary>
            <React.Fragment>
              {/* The ready WebUI requires the real .app-holder > div flex box
                  for its responsive width/alignment. When the privacy gate
                  is showing (and the UI is detached), this empty host must
                  be boxless so it does not displace the retry/loading UI.
                  The inner privacy root always stays display: contents. */}
              <div ref={this.setUiPortalHost} style={boot === 'ready' ? undefined : { display: 'contents' }} />
              {ui}
              {boot === 'ready' && emojiMuteBypassEnabled() && (
                <div className='emoji-mutes-bypass-notice' role='status'>
                  <FormattedMessage id='emoji_mutes.bypass_active' defaultMessage='Emoji muting is disabled in this tab. Your saved settings are unchanged.' />
                  <button type='button' onClick={this.restoreEmojiMutes}>
                    <FormattedMessage id='emoji_mutes.bypass_restore' defaultMessage='Turn emoji muting back on' />
                  </button>
                </div>
              )}
              {showBootPanel && (
                <div className='emoji-mutes-bootstrap' role={boot === 'error' ? 'alert' : 'status'} style={{ padding: '2rem', textAlign: 'center' }}>
                  {bootContent}
                  {boot !== 'session-changed' && (
                    <React.Fragment>
                      <button type='button' onClick={this.startWithoutEmojiMutes}>
                        <FormattedMessage id='emoji_mutes.bootstrap_skip' defaultMessage='Start without emoji muting' />
                      </button>
                      <p><FormattedMessage id='emoji_mutes.bootstrap_skip_note' defaultMessage='Muted emoji may become visible. Your saved settings will not change.' /></p>
                      {this.state.bypassStorageError && (
                        <p role='alert'><FormattedMessage id='emoji_mutes.bootstrap_skip_unavailable' defaultMessage='Unable to restart without emoji muting. Browser session storage may be blocked.' /></p>
                      )}
                    </React.Fragment>
                  )}
                </div>
              )}
            </React.Fragment>
          </ErrorBoundary>
        </Provider>
      </IntlProvider>
    );
  }

}
