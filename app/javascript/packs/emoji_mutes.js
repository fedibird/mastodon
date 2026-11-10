import './public-path';
import React from 'react';
import ReactDOM from 'react-dom';
import { IntlProvider, addLocaleData } from 'react-intl';
import ready from '../mastodon/ready';
import loadPolyfills from '../mastodon/load_polyfills';
import { getLocale } from '../mastodon/locales';
import EmojiMuteSettings from '../mastodon/features/emoji/emoji_mute_settings';

loadPolyfills().then(() => {
  ready(() => {
    const node = document.getElementById('emoji-mutes');

    if (!node) {
      return;
    }

    const { localeData, messages } = getLocale();
    addLocaleData(localeData);
    ReactDOM.render(<IntlProvider locale={document.documentElement.lang} messages={messages}><EmojiMuteSettings /></IntlProvider>, node);
  });
}).catch(console.error);
