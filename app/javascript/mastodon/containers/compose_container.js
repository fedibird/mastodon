import React from 'react';
import { Provider } from 'react-redux';
import PropTypes from 'prop-types';
import configureStore from '../store/configureStore';
import { hydrateStore } from '../actions/store';
import { IntlProvider, addLocaleData } from 'react-intl';
import { getLocale } from '../locales';
import Compose from '../features/standalone/compose';
import initialState from '../initial_state';
import { fetchCircles } from '../actions/circles';
import { ensureCustomEmojis } from '../actions/custom_emojis';
import { bootStandaloneEmojiMutes } from '../actions/emoji_mutes';
import StandaloneEmojiMuteRetry from '../features/emoji/standalone_emoji_mute_retry';
import { preloadCustomEmojiCatalogIfNeeded, preloadStandardEmojiPickerIfNeeded } from '../features/emoji/emoji_picker_preferences';

const { localeData, messages } = getLocale();
addLocaleData(localeData);

const store = configureStore();

if (initialState) {
  store.dispatch(hydrateStore(initialState));
}

store.dispatch(fetchCircles());
store.dispatch(bootStandaloneEmojiMutes());
preloadStandardEmojiPickerIfNeeded();
// Standalone compose needs the standard catalog but not the private stock.
preloadCustomEmojiCatalogIfNeeded(() => store.dispatch(ensureCustomEmojis()));

export default class TimelineContainer extends React.PureComponent {

  static propTypes = {
    locale: PropTypes.string.isRequired,
  };

  render () {
    const { locale } = this.props;

    return (
      <IntlProvider locale={locale} messages={messages}>
        <Provider store={store}>
          <StandaloneEmojiMuteRetry />
          <Compose />
        </Provider>
      </IntlProvider>
    );
  }

}
