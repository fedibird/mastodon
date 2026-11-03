import { act, fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import React from 'react';
import { MemoryRouter, Route } from 'react-router-dom';
import { addLocaleData, IntlProvider } from 'react-intl';
import japaneseData from 'react-intl/locale-data/ja';
import japanese from 'mastodon/locales/ja.json';

jest.mock('mastodon/actions/settings', () => ({
  changeSetting: (path, value) => ({ type: 'SETTING_CHANGE', path, value }),
}));

import AccountHashtagFilter from '../hashtag_filter';
import ColumnSettingsContainer from 'mastodon/features/account_timeline/containers/column_settings_container';

addLocaleData(japaneseData);

const makeStore = () => createStore((state = fromJS({
  settings: { account: { other: { advancedMode: true, hideHashtagInput: false } } },
}), action) => (
  action.type === 'SETTING_CHANGE' ? state.setIn(['settings', ...action.path], action.value) : state
));

const renderRoute = (routeBase, initialRoute) => {
  const store = makeStore();
  const output = render(
    <Provider store={store}>
      <IntlProvider locale='ja' messages={japanese}>
        <MemoryRouter initialEntries={[initialRoute]}>
          <Route render={({ location }) => <span data-testid='pathname'>{location.pathname}</span>} />
          <AccountHashtagFilter accountId='123' routeBase={routeBase} />
        </MemoryRouter>
      </IntlProvider>
    </Provider>,
  );

  return { store, ...output };
};

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
      <Provider store={makeStore()}>
        <IntlProvider locale='ja' messages={japanese}>
          <AccountHashtagFilter accountId='123' onSelectTag={onSelectTag} />
        </IntlProvider>
      </Provider>,
    );

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: '＃test' } });
    fireEvent.click(screen.getByRole('button', { name: '絞り込む' }));
    expect(onSelectTag).toHaveBeenCalledWith('test');
  });

  it('synchronizes the leading close button with the account column setting', () => {
    const store = makeStore();

    render(
      <Provider store={store}>
        <IntlProvider locale='ja' messages={japanese}>
          <AccountHashtagFilter accountId='123' />
          <ColumnSettingsContainer />
        </IntlProvider>
      </Provider>,
    );

    const featuredToggle = screen.getByRole('checkbox', { name: '注目のタグの選択を隠す' });
    const toggle = screen.getByRole('checkbox', { name: 'ハッシュタグ入力欄を隠す' });
    expect(featuredToggle.compareDocumentPosition(toggle) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(toggle).not.toBeChecked();
    expect(screen.getByRole('searchbox', { name: 'ハッシュタグで絞り込み' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'ハッシュタグ入力欄を閉じる' }));
    expect(store.getState().getIn(['settings', 'account', 'other', 'hideHashtagInput'])).toBe(true);
    expect(screen.queryByRole('searchbox', { name: 'ハッシュタグで絞り込み' })).toBeNull();
    expect(toggle).toBeChecked();

    fireEvent.click(toggle);
    expect(store.getState().getIn(['settings', 'account', 'other', 'hideHashtagInput'])).toBe(false);
    expect(screen.getByRole('searchbox', { name: 'ハッシュタグで絞り込み' })).toBeInTheDocument();

    act(() => {
      store.dispatch({ type: 'SETTING_CHANGE', path: ['account', 'other', 'hideHashtagInput'], value: true });
    });
    expect(screen.queryByRole('searchbox')).toBeNull();
  });

  it('shows the hashtag-input setting only in detailed mode', () => {
    const store = makeStore();
    render(
      <Provider store={store}>
        <IntlProvider locale='ja' messages={japanese}>
          <ColumnSettingsContainer />
        </IntlProvider>
      </Provider>,
    );

    expect(screen.getByRole('checkbox', { name: 'ハッシュタグ入力欄を隠す' })).toBeInTheDocument();
    act(() => {
      store.dispatch({ type: 'SETTING_CHANGE', path: ['account', 'other', 'advancedMode'], value: false });
    });

    expect(screen.queryByRole('checkbox', { name: 'ハッシュタグ入力欄を隠す' })).toBeNull();
    expect(screen.getByRole('checkbox', { name: '詳細モード' })).not.toBeChecked();

    // The setting is retained when detailed mode is enabled again.
    fireEvent.click(screen.getByRole('checkbox', { name: '詳細モード' }));
    expect(screen.getByRole('checkbox', { name: 'ハッシュタグ入力欄を隠す' })).toBeInTheDocument();
  });
});
