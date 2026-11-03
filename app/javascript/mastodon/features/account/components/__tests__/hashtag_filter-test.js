import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import { MemoryRouter, Route } from 'react-router-dom';
import { addLocaleData, IntlProvider } from 'react-intl';
import japaneseData from 'react-intl/locale-data/ja';
import japanese from 'mastodon/locales/ja.json';

import AccountHashtagFilter from '../hashtag_filter';

addLocaleData(japaneseData);

const renderRoute = (routeBase, initialRoute) => render(
  <IntlProvider locale='ja' messages={japanese}>
    <MemoryRouter initialEntries={[initialRoute]}>
      <Route render={({ location }) => <span data-testid='pathname'>{location.pathname}</span>} />
      <AccountHashtagFilter accountId='123' routeBase={routeBase} />
    </MemoryRouter>
  </IntlProvider>,
);

describe('shared account hashtag input', () => {
  it.each(['posts', 'with_replies', 'about'])('keeps the current %s tab after filtering', part => {
    const base = `/accounts/123/${part}`;
    renderRoute(base, base);

    fireEvent.change(screen.getByRole('searchbox', { name: 'ハッシュタグで絞り込み' }), { target: { value: '#猫' } });
    fireEvent.click(screen.getByRole('button', { name: '絞り込む' }));

    expect(screen.getByTestId('pathname')).toHaveTextContent(`${base}/${encodeURIComponent('猫')}`);
  });

  it('uses the media view callback without navigating away from it', () => {
    const onSelectTag = jest.fn();
    render(
      <IntlProvider locale='ja' messages={japanese}>
        <AccountHashtagFilter accountId='123' onSelectTag={onSelectTag} />
      </IntlProvider>,
    );

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: '＃test' } });
    fireEvent.click(screen.getByRole('button', { name: '絞り込む' }));
    expect(onSelectTag).toHaveBeenCalledWith('test');
  });
});
