import React from 'react';
import { createPortal } from 'react-dom';
import { Provider } from 'react-redux';
import PropTypes from 'prop-types';
import configureStore from '../store/configureStore';
import { BrowserRouter, Route } from 'react-router-dom';
import { ScrollContext } from 'react-router-scroll-4';
import UI from '../features/ui';
import { settingsReturnScroll, settleSettingsReturnScroll } from '../features/embedded_rails_settings/navigation';
import { prefetchCircles } from '../actions/circles';
import { ensureCustomEmojis } from '../actions/custom_emojis';
import { preloadEmojiPickersIfNeeded } from '../features/emoji/emoji_picker_preferences';
import { hydrateStore } from '../actions/store';
import { startMastodonSubscriptions } from './mastodon_subscriptions';
import { IntlProvider, addLocaleData } from 'react-intl';
import EmojiMuteLoadNotice, { EmojiMuteNoticeContext } from '../components/emoji_mute_load_notice';
import { invalidateEmojiMuteAsyncWork, retryEmojiMuteLoad, ignoreEmojiMutesThisView, disableEmojiMuteFeature, emojiMuteSyncInFlight, EMOJI_MUTES_RESET } from '../actions/emoji_mutes';
import { classifyEmojiMuteFetchError } from '../features/emoji/emoji_mute_fetch_error';
import { resetEmojiMuteSession } from '../features/emoji/emoji_mute_store';
import { currentEmojiMuteBoot } from '../features/emoji/emoji_mute_availability';
import { createUnverifiedEmojiGuard } from '../features/emoji/emoji_mute_live_dom';
import { setEmojiActionsOverlayPrivacyContainer } from '../features/emoji/emoji_actions/overlay_root';
import { getLocale } from '../locales';
import initialState from '../initial_state';
import ErrorBoundary from '../components/error_boundary';

const { localeData, messages } = getLocale();
addLocaleData(localeData);

export const store = configureStore();
const hydrateAction = hydrateStore(initialState);

store.dispatch(hydrateAction);
store.dispatch(prefetchCircles());

// Registered before any connected component. The walk runs only when display
// enters suppress, and it leaves React's nodes in place. Compose fields are
// skipped because their values are not text nodes.
const unverifiedEmojiGuard = createUnverifiedEmojiGuard();

export function scrubVisibleEmojiIfUnverified() {
  unverifiedEmojiGuard(store.getState());
}

scrubVisibleEmojiIfUnverified.reset = () => unverifiedEmojiGuard.reset();

store.subscribe(scrubVisibleEmojiIfUnverified);
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
    emojiMuteBoot: 'ready',
    emojiMuteFailure: null,
    preferenceError: false,
    preferenceSaving: false,
  };

  // Consecutive Redux actions may be batched before React commits setState.
  // Compare the requested phase as well as the committed one so a stale
  // action always supersedes an earlier ready action in the same batch.
  requestedBootPhase = 'ready';

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

  componentDidMount() {
    this.mounted = true;
    this.uiPortalRoot.className = 'emoji-mutes-privacy-portal';
    setEmojiActionsOverlayPrivacyContainer(this.uiPortalRoot);
    this.unsubscribeEmojiMutes = store.subscribe(this.observeEmojiMuteState);
    this.uiInitialized = true;
    this.uiPortalRoot.style.display = 'contents';
    this.attachUiPortal();
    this.bootstrapComplete = true;
    this.startSubscriptions();

    // Known-disabled viewers keep their saved rules but do not fetch them at
    // boot. Unknown and enabled viewers fetch in the background. The WebUI
    // is already mounted; unverified emoji are omitted from the content.
    if (signedIn && currentEmojiMuteBoot().fetch) {
      this.bootstrapEmojiMutes();
    }

    this.forceUpdate();
  }

  componentWillUnmount () {
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

  // A newer streaming revision suppresses emoji in Redux. The module-level
  // subscriber already removed the previous images and labels from the live
  // document. This observer only moves the notice and isolates a changed
  // session. The WebUI stays mounted, and compose drafts stay in their fields.
  observeEmojiMuteState = () => {
    if (!this.mounted || this.sessionChanged) {
      return;
    }

    const state = store.getState();

    if (!sessionMatches(state)) {
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
    const availability = state.getIn(['emojiMutes', 'availability']);
    let next = this.requestedBootPhase;

    const syncing = emojiMuteSyncInFlight();

    if (availability === 'temporary_ignore') {
      next = 'ignored';
    } else if (phase === 'ready') {
      next = 'ready';
    } else if (syncing || (phase === 'loading' && this.emojiMuteRequestInFlight)) {
      // Hide the previous card only while the newest sync is still pending.
      // An older request, and a finished failure left in loading, do not.
      next = 'loading';
    } else if (phase === 'error') {
      next = 'error';
    }

    if (next !== 'ready' && next !== 'error' && next !== 'ignored' && next !== 'loading') {
      return;
    }

    const failure = next === 'error' ? (state.getIn(['emojiMutes', 'failure']) || 'unavailable') : null;

    if (next !== this.requestedBootPhase || failure !== this.state.emojiMuteFailure) {
      this.requestedBootPhase = next;
      this.setState({
        emojiMuteBoot: next,
        emojiMuteFailure: failure,
        preferenceError: next === 'ready' ? false : this.state.preferenceError,
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
    this.setState({ preferenceError: false });

    // The WebUI is already mounted. The first GET skips the notification
    // refresh because the columns are mounting. A later retry must restore them.
    const initialDocumentFetch = !this.emojiMuteInitialFetchStarted;
    this.emojiMuteInitialFetchStarted = true;
    store.dispatch(retryEmojiMuteLoad({ bootstrap: initialDocumentFetch })).then(result => {
      if (generation !== this.bootstrapGeneration) {
        return;
      }

      this.emojiMuteRequestInFlight = false;

      if (!this.mounted || this.sessionChanged) {
        return;
      }

      // The newer sync already changed Redux. This completion does not.
      if (result && result.superseded) {
        this.bootstrapComplete = true;
        this.observeEmojiMuteState();
        return;
      }

      this.bootstrapComplete = true;
      const muteState = store.getState();
      const availability = muteState.getIn(['emojiMutes', 'availability']);

      if (availability === 'temporary_ignore') {
        this.requestedBootPhase = 'ignored';
        this.setState({ emojiMuteBoot: 'ignored', emojiMuteFailure: null });
        return;
      }

      const phase = muteState.getIn(['emojiMutes', 'phase']);
      if (phase !== 'ready') {
        const failure = muteState.getIn(['emojiMutes', 'failure']) || 'unavailable';
        this.requestedBootPhase = 'error';
        if (failure === 'unavailable') {
          this.retryReadyAt = Date.now() + EMOJI_MUTE_RETRY_COOLDOWN_MS;
        }
        this.setState({ emojiMuteBoot: 'error', emojiMuteFailure: failure });
        return;
      }

      this.requestedBootPhase = 'ready';
      this.setState({ emojiMuteBoot: 'ready', emojiMuteFailure: null });
    }).catch(error => {
      if (generation !== this.bootstrapGeneration) {
        return;
      }

      this.emojiMuteRequestInFlight = false;

      // A newer sync already replaced this GET. Its completion owns the card.
      if (error && error.superseded) {
        return;
      }

      if (!this.mounted || this.sessionChanged) {
        return;
      }

      const availability = store.getState().getIn(['emojiMutes', 'availability']);

      if (availability === 'temporary_ignore' || availability === 'disabled') {
        return;
      }

      const failure = classifyEmojiMuteFetchError(error);
      this.bootstrapComplete = true;
      this.requestedBootPhase = 'error';

      if (failure === 'unavailable') {
        this.retryReadyAt = Date.now() + EMOJI_MUTE_RETRY_COOLDOWN_MS;
      }

      this.setState({ emojiMuteBoot: 'error', emojiMuteFailure: failure });
    });
  };

  ignoreEmojiMutes = () => {
    store.dispatch(ignoreEmojiMutesThisView());
  };

  turnEmojiMutesOff = () => {
    if (this.state.preferenceSaving) {
      return;
    }

    this.setState({ preferenceSaving: true, preferenceError: false });
    store.dispatch(disableEmojiMuteFeature()).then(data => {
      if (!this.mounted || this.sessionChanged) {
        return;
      }

      if (!data || data.applied !== true || data.enabled !== false) {
        this.setState({ preferenceSaving: false, preferenceError: true });
        return;
      }

      this.requestedBootPhase = 'ready';
      this.setState({
        preferenceSaving: false,
        preferenceError: false,
        emojiMuteBoot: 'ready',
        emojiMuteFailure: null,
      });
    }).catch(() => {
      if (!this.mounted || this.sessionChanged) {
        return;
      }

      this.setState({ preferenceSaving: false, preferenceError: true });
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

  render () {
    const { locale } = this.props;
    const boot = this.state.emojiMuteBoot;
    const sessionChanged = boot === 'session-changed';
    const noticeValue = {
      boot,
      failure: this.state.emojiMuteFailure,
      preferenceSaving: this.state.preferenceSaving,
      preferenceError: this.state.preferenceError,
      onRetry: this.bootstrapEmojiMutes,
      onIgnore: this.ignoreEmojiMutes,
      onDisable: this.turnEmojiMutesOff,
      onReload: this.reloadPage,
    };

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
            <EmojiMuteNoticeContext.Provider value={noticeValue}>
              <div ref={this.setUiPortalHost} style={sessionChanged ? { display: 'contents' } : undefined} />
              {ui}
              {sessionChanged && (
                <div className='emoji-mute-load-notice-slot'>
                  <EmojiMuteLoadNotice placement='session' />
                </div>
              )}
            </EmojiMuteNoticeContext.Provider>
          </ErrorBoundary>
        </Provider>
      </IntlProvider>
    );
  }

}
