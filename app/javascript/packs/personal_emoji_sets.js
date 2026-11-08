import './public-path';
import React from 'react';
import ReactDOM from 'react-dom';
import { IntlProvider, addLocaleData } from 'react-intl';
import ready from '../mastodon/ready';
import loadPolyfills from '../mastodon/load_polyfills';
import { getLocale } from '../mastodon/locales';
import PersonalEmojiSetEditor from '../mastodon/features/emoji/personal_emoji_set_editor';

loadPolyfills().then(() => {
  ready(() => {
    const node = document.getElementById('personal-emoji-sets');

    if (!node) {
      return;
    }

    const { localeData, messages } = getLocale();
    addLocaleData(localeData);
    ReactDOM.render(<IntlProvider locale={document.documentElement.lang} messages={messages}><PersonalEmojiSetEditor /></IntlProvider>, node);
  });
}).catch(console.error);
