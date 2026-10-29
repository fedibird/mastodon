/* eslint-disable react/prop-types -- The intl stand-in is test plumbing. */
import { render, screen } from '@testing-library/react';
import React from 'react';

// react-intl 2 cannot load in this checkout: intl-relativeformat 6 has no
// __addLocaleData. This provider still updates a child message when the
// catalog changes, which is the case the labels have to follow.
jest.mock('react-intl', () => {
  const ReactIntl = require('react');
  const Catalog = ReactIntl.createContext({ messages: {} });
  const textOf = (messages, { id, defaultMessage }) => (messages && messages[id]) || defaultMessage;

  const FormattedMessage = (props) => {
    const { messages } = ReactIntl.useContext(Catalog);
    const text = textOf(messages, props);

    if (typeof props.children === 'function') {
      return props.children(text);
    }

    return text;
  };

  return {
    IntlProvider: ({ messages, children }) => (
      <Catalog.Provider value={{ messages: messages || {} }}>{children}</Catalog.Provider>
    ),
    FormattedMessage,
  };
});

import { IntlProvider } from 'react-intl';

import ExternalPlayerActions from '../actions';

const onPin = () => {};
const onClose = () => {};

const messages = (popOut, closePlayer, controls) => ({
  'external_media.pop_out': popOut,
  'external_media.close': closePlayer,
  'external_media.player_controls': controls,
  'external_media.return_to_post': 'Return to the post',
});

describe('external player action labels', () => {
  it('keeps the accessible name and tooltip on the translated string when the locale changes', () => {
    const view = render(
      <IntlProvider locale='en' messages={messages('Pop out the player', 'Close the player', 'Player controls')}>
        <ExternalPlayerActions onPin={onPin} onClose={onClose} />
      </IntlProvider>,
    );

    expect(screen.getByRole('button', { name: 'Pop out the player' }).title).toBe('Pop out the player');
    expect(screen.getByRole('button', { name: 'Close the player' }).title).toBe('Close the player');

    view.rerender(
      <IntlProvider locale='ja' messages={messages('プレイヤーをポップアウト', 'プレイヤーを閉じる', 'プレイヤーの操作')}>
        <ExternalPlayerActions onPin={onPin} onClose={onClose} />
      </IntlProvider>,
    );

    expect(screen.getByRole('button', { name: 'プレイヤーをポップアウト' }).title).toBe('プレイヤーをポップアウト');
    expect(screen.getByRole('button', { name: 'プレイヤーを閉じる' }).title).toBe('プレイヤーを閉じる');
    expect(screen.getByRole('group', { name: 'プレイヤーの操作' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Pop out the player' })).toBeNull();
  });
});
