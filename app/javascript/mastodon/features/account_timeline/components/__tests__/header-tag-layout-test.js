import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS, List as ImmutableList } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { MemoryRouter } from 'react-router-dom';
import { addLocaleData, IntlProvider } from 'react-intl';
import japaneseData from 'react-intl/locale-data/ja';
import japanese from 'mastodon/locales/ja.json';

jest.mock('mastodon/features/account/components/header', () => () => null);
jest.mock('mastodon/features/account/components/header_common', () => () => null);
jest.mock('mastodon/features/account/components/header_extra', () => () => null);
jest.mock('mastodon/features/account/components/header_extra_links', () => {
  const ReactMock = require('react');
  return () => ReactMock.createElement('div', { 'data-testid': 'account-links' });
});

import Header from '../header';

addLocaleData(japaneseData);

const account = fromJS({ id: '123', username: 'someone', acct: 'someone', url: 'https://example.org/@someone' });
const actions = [
  'onFollow', 'onSubscribe', 'onAddToList', 'onBlock', 'onMention',
  'onDirect', 'onConversations', 'onReblogToggle', 'onReport', 'onMute',
  'onBlockDomain', 'onUnblockDomain', 'onEndorseToggle', 'onAddToCircle',
].reduce((result, name) => ({ ...result, [name]: jest.fn() }), {});

const store = createStore(() => fromJS({
  settings: { account: { other: { hideHashtagInput: false } } },
  user_lists: {
    featured_tags: {
      '123': { items: [{ name: 'cats', statuses_count: 5 }] },
    },
  },
}));

const renderHeader = (props = {}) => render(
  <Provider store={store}>
    <IntlProvider locale='ja' messages={japanese}>
      <MemoryRouter>
        <Header
          account={account}
          identity_proofs={ImmutableList()}
          advancedMode
          tagged={null}
          domain='example.org'
          showTagSearch
          hideFeaturedTags={false}
          hideProfile
          {...actions}
          {...props}
        />
      </MemoryRouter>
    </IntlProvider>
  </Provider>,
);

describe('account header hashtag layout', () => {
  it('places featured tag choices then hashtag input ahead of account details', () => {
    const onSelectTag = jest.fn();
    const { container } = renderHeader({ onSelectTag, hideRelation: false });
    const featured = container.querySelector('.account__header__extra__hashtag-links');
    const input = screen.getByRole('searchbox', { name: 'ハッシュタグで絞り込み' });
    const links = screen.getByTestId('account-links');

    expect(featured).toBeInTheDocument();
    expect(featured.compareDocumentPosition(input) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(input.compareDocumentPosition(links) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    fireEvent.click(screen.getByRole('link', { name: /#cats/ }));
    expect(onSelectTag).toHaveBeenCalledWith('cats');
  });

  it('does not render a hashtag input in standard mode', () => {
    renderHeader({ advancedMode: false });
    expect(screen.queryByRole('searchbox', { name: 'ハッシュタグで絞り込み' })).toBeNull();
    expect(screen.queryByRole('link', { name: /#cats/ })).toBeNull();
  });

  it('keeps the input when only featured tags are hidden', () => {
    renderHeader({ hideFeaturedTags: true });
    expect(screen.queryByRole('link', { name: /#cats/ })).toBeNull();
    expect(screen.getByRole('searchbox', { name: 'ハッシュタグで絞り込み' })).toBeInTheDocument();
  });
});
