import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { addLocaleData, IntlProvider } from 'react-intl';
import japaneseLocaleData from 'react-intl/locale-data/ja';

import japaneseMessages from 'mastodon/locales/ja.json';

jest.mock('mastodon/initial_state', () => ({
  enableEmptyColumn: false,
  defaultColumnWidth: 'x100',
}));

jest.mock('mastodon/components/icon', () => {
  const ReactMock = require('react');
  return () => ReactMock.createElement('span');
});

import ColumnHeader from '../column_header';

const noop = () => {};

addLocaleData(japaneseLocaleData);

describe('ColumnHeader Japanese display mode selector', () => {
  it('renders each label as localized plain option text', () => {
    const state = fromJS({ settings: { home: {}, columns: [] } });
    const store = createStore((previous = state) => previous);

    const { container } = render(
      <IntlProvider locale='ja' messages={japaneseMessages}>
        <Provider store={store}>
          <ColumnHeader
            title='ホーム'
            icon='home'
            layoutScope='home'
            multiColumn
            columnWidth='x100'
            onPin={noop}
            onMove={noop}
            onClick={noop}
          />
        </Provider>
      </IntlProvider>,
    );

    fireEvent.click(screen.getByRole('button', { name: '設定を表示' }));

    const select = screen.getByRole('combobox', { name: '表示方法' });
    expect(Array.from(select.options).map(option => option.textContent)).toEqual([
      '通常',
      'カード（1列）',
      'カード（2列）',
      'カード（3列）',
      'メディア',
    ]);
    expect(select.querySelector('span')).toBeNull();
    expect(container.querySelector('option[value="card-3"]')).toHaveTextContent('カード（3列）');
    expect(screen.getByText('200%')).toBeInTheDocument();
  });

  it('hides the redundant media mode from account posts even if it was saved previously', () => {
    const state = fromJS({ settings: { account: { layoutMode: 'media' }, columns: [] } });
    const store = createStore((previous = state) => previous);

    render(
      <IntlProvider locale='ja' messages={japaneseMessages}>
        <Provider store={store}>
          <ColumnHeader
            title='アカウント'
            icon='user'
            layoutScope='account'
            multiColumn
            columnWidth='x100'
            onPin={noop}
            onMove={noop}
            onClick={noop}
          />
        </Provider>
      </IntlProvider>,
    );

    fireEvent.click(screen.getByRole('button', { name: '設定を表示' }));
    const select = screen.getByRole('combobox', { name: '表示方法' });

    expect(select).toHaveValue('normal');
    expect(Array.from(select.options).map(option => option.value)).toEqual([
      'normal', 'card-1', 'card-2', 'card-3',
    ]);
  });
});
