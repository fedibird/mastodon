import React from 'react';
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
import { syncEmojiMutes, EMOJI_MUTES_RESET } from '../actions/emoji_mutes';
import { resetEmojiMuteSession } from '../features/emoji/emoji_mute_store';
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

// Do not mount any WebUI surfaces (including labels/alt text) before the
// first authoritative mute document has arrived. The user may have muted an
// emoji which cannot be inferred from the shared status HTML alone.
const signedIn = !!(initialState?.meta?.me || initialState?.meta?.access_token);

export default class Mastodon extends React.PureComponent {

  static propTypes = {
    locale: PropTypes.string.isRequired,
  };

  state = {
    emojiMuteBoot: signedIn ? 'loading' : 'ready',
  };

  componentDidMount() {
    this.mounted = true;

    if (signedIn) {
      this.bootstrapEmojiMutes();
    } else {
      this.startSubscriptions();
    }
  }

  componentWillUnmount () {
    this.mounted = false;

    if (this.disconnect) {
      this.disconnect();
      this.disconnect = null;
    }

    // The same JS runtime must never carry a signed-in viewer's rules into a
    // later shell. Late GET promises are invalidated by the session counter.
    resetEmojiMuteSession();
    store.dispatch({ type: EMOJI_MUTES_RESET });
  }

  startSubscriptions = () => {
    if (!this.disconnect && this.mounted) {
      this.disconnect = startMastodonSubscriptions(store);
    }
  };

  bootstrapEmojiMutes = () => {
    this.setState({ emojiMuteBoot: 'loading' });

    store.dispatch(syncEmojiMutes({ bootstrap: true })).then(() => {
      if (!this.mounted) {
        return;
      }

      // A stale server answer can resolve without applying a document. That
      // is not permission to reveal the hydrated timeline.
      if (store.getState().getIn(['emojiMutes', 'phase']) !== 'ready') {
        this.setState({ emojiMuteBoot: 'error' });
        return;
      }

      this.setState({ emojiMuteBoot: 'ready' }, this.startSubscriptions);
    }).catch(() => {
      if (this.mounted) {
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

  render () {
    const { locale } = this.props;

    const boot = this.state.emojiMuteBoot;
    const body = boot === 'ready' ? (
      <BrowserRouter basename='/web'>
        <ScrollContext shouldUpdateScroll={this.shouldUpdateScroll}>
          <Route path='/' component={UI} />
        </ScrollContext>
      </BrowserRouter>
    ) : (
      <div className='emoji-mutes-bootstrap' role={boot === 'error' ? 'alert' : 'status'} style={{ padding: '2rem', textAlign: 'center' }}>
        {boot === 'loading' ? (
          <FormattedMessage id='emoji_mutes.bootstrap_loading' defaultMessage='Loading emoji mute settings…' />
        ) : (
          <React.Fragment>
            <p><FormattedMessage id='emoji_mutes.bootstrap_error' defaultMessage='Emoji mute settings could not be verified. Posts are hidden until you retry.' /></p>
            <button type='button' onClick={this.bootstrapEmojiMutes}>
              <FormattedMessage id='emoji_mutes.bootstrap_retry' defaultMessage='Retry loading settings' />
            </button>
          </React.Fragment>
        )}
      </div>
    );

    return (
      <IntlProvider locale={locale} messages={messages}>
        <Provider store={store}>
          <ErrorBoundary>{body}</ErrorBoundary>
        </Provider>
      </IntlProvider>
    );
  }

}
