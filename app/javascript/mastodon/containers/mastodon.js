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
import { preloadEmojiPickersIfNeeded } from '../features/emoji/emoji_picker_preferences';
import { hydrateStore } from '../actions/store';
import { startMastodonSubscriptions } from './mastodon_subscriptions';
import { IntlProvider, addLocaleData, FormattedMessage } from 'react-intl';
import { syncEmojiMutes, invalidateEmojiMuteAsyncWork, EMOJI_MUTES_RESET } from '../actions/emoji_mutes';
import { resetEmojiMuteSession } from '../features/emoji/emoji_mute_store';
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
preloadEmojiPickersIfNeeded();

// The rules are scoped to the authenticated viewer. The bootstrap credential
// cannot be switched in-place: changing accounts requires a fresh application
// initialization so every cached status and mute projection belongs to one
// viewer.
const signedIn = !!(initialState?.meta?.me || initialState?.meta?.access_token);
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
  };

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
      this.detachUiPortal();
      setEmojiActionsOverlayPrivacyContainer(null);
      this.uiInitialized = false;
      this.sessionChanged = true;
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

    if (next !== this.state.emojiMuteBoot) {
      if (next !== 'ready') {
        // Detach synchronously when the Redux revision changes, before any
        // existing display subscription can expose unverified emoji content.
        this.detachUiPortal();
      }

      this.setState({ emojiMuteBoot: next }, () => {
        if (next === 'ready' && this.mounted && !this.sessionChanged) {
          // Keep the portal detached while its subscribed display nodes
          // reconcile the new document; move back the *same* DOM afterwards.
          this.attachUiPortal();
        }
      });
    }
  };

  bootstrapEmojiMutes = () => {
    const generation = (this.bootstrapGeneration || 0) + 1;
    this.bootstrapGeneration = generation;
    this.setState({ emojiMuteBoot: 'loading' });

    store.dispatch(syncEmojiMutes({ bootstrap: true })).then(() => {
      if (!this.mounted || this.sessionChanged || generation !== this.bootstrapGeneration) {
        return;
      }

      this.bootstrapComplete = true;
      // A stale server answer can resolve without applying a document. That
      // is not permission to reveal the hydrated timeline.
      const phase = store.getState().getIn(['emojiMutes', 'phase']);
      if (phase !== 'ready') {
        this.setState({ emojiMuteBoot: 'error' });
        return;
      }

      this.uiInitialized = true;
      this.uiPortalRoot.style.display = 'contents';
      // Attach an empty portal root before the first UI mount, so layout
      // measurements at componentDidMount see the actual page geometry.
      this.attachUiPortal();
      this.setState({ emojiMuteBoot: 'ready' }, this.startSubscriptions);
    }).catch(() => {
      if (this.mounted && !this.sessionChanged && generation === this.bootstrapGeneration) {
        this.bootstrapComplete = true;
        this.setState({ emojiMuteBoot: 'error' });
      }
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
    let bootContent;

    if (boot === 'loading') {
      bootContent = <FormattedMessage id='emoji_mutes.bootstrap_loading' defaultMessage='Loading emoji mute settings…' />;
    } else if (boot === 'session-changed') {
      bootContent = (
        <React.Fragment>
          <p><FormattedMessage id='emoji_mutes.session_changed' defaultMessage='Your account changed. Reload to protect your emoji mute settings.' /></p>
          <button type='button' onClick={this.reloadPage}>
            <FormattedMessage id='emoji_mutes.session_reload' defaultMessage='Reload the page' />
          </button>
        </React.Fragment>
      );
    } else {
      bootContent = (
        <React.Fragment>
          <p><FormattedMessage id='emoji_mutes.bootstrap_error' defaultMessage='Emoji mute settings could not be verified. Posts are hidden until you retry.' /></p>
          <button type='button' onClick={this.bootstrapEmojiMutes}>
            <FormattedMessage id='emoji_mutes.bootstrap_retry' defaultMessage='Retry loading settings' />
          </button>
        </React.Fragment>
      );
    }

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
              <div ref={this.setUiPortalHost} style={{ display: 'contents' }} />
              {ui}
              {boot !== 'ready' && (
                <div className='emoji-mutes-bootstrap' role={boot === 'error' ? 'alert' : 'status'} style={{ padding: '2rem', textAlign: 'center' }}>
                  {bootContent}
                </div>
              )}
            </React.Fragment>
          </ErrorBoundary>
        </Provider>
      </IntlProvider>
    );
  }

}
