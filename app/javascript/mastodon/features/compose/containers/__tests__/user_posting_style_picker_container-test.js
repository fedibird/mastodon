import compose from '../../../../reducers/compose';
import { PRIMARY_COMPOSER_ID } from '../../../../utils/composer';
import { MemoryRouter } from 'react-router-dom';
import { act, fireEvent, render as renderView, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) {
        return defaultMessage;
      }

      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

jest.mock('../../../../initial_state', () => ({
  isAdministrator: true,
  showComposerPostingStyleSelector: true,
}));

import { USER_POSTING_STYLES_FETCH_SUCCESS } from '../../../../actions/user_posting_styles';
import { applyComposerSurface, createComposer } from '../../../../actions/composer';
import { groupPostingContext } from '../../../../posting_context/fixtures/group_context_fixture';
import composers from '../../../../reducers/composers';
import userPostingStyles from '../../../../reducers/user_posting_styles';
import { ComposerProvider } from '../../composer_id_context';
import UserPostingStylePicker from '../user_posting_style_picker_container';

const render = ui => {
  const view = renderView(<MemoryRouter>{ui}</MemoryRouter>);
  return { ...view, rerender: next => view.rerender(<MemoryRouter>{next}</MemoryRouter>) };
};

const style = (id, name, target) => fromJS({
  id,
  name,
  revision: 1,
  target,
  defaults: { visibility: 'public' },
  managed: { hashtags: [] },
});

const catalog = ImmutableList([
  style('group-a', 'Group A', { kind: 'group', accountId: '111', hashtag: null, label: 'group-a' }),
  style('group-b', 'Group B', { kind: 'group', accountId: '222', hashtag: null, label: 'group-b' }),
  style('books', 'Books', { kind: 'hashtag', accountId: null, hashtag: 'books', label: '#books' }),
  style('news', 'News', { kind: 'hashtag', accountId: null, hashtag: 'news', label: '#news' }),
  style('common', 'Common', { kind: 'none', accountId: null, hashtag: null, label: null }),
]);

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('composers', composers(state.get('composers'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action));
};

const storeFor = (composerId, surface) => {
  const store = createStore(reduce, ImmutableMap({
    composers: composers(undefined, createComposer(composerId)),
    userPostingStyles: userPostingStyles(undefined, {
      type: USER_POSTING_STYLES_FETCH_SUCCESS,
      styles: catalog,
    }),
    relationships: ImmutableMap(),
  }));

  store.dispatch(applyComposerSurface(
    composerId,
    surface,
    surface.kind === 'group' ? groupPostingContext : null,
    surface.kind === 'group' ? surface.key : null,
  ));

  return store;
};

const optionNames = () => screen.getAllByRole('menuitemradio').map(item => item.textContent);

const renderPicker = (composerId, surface) => {
  const store = storeFor(composerId, surface);

  render(
    <Provider store={store}>
      <ComposerProvider composerId={composerId}>
        <UserPostingStylePicker />
      </ComposerProvider>
    </Provider>,
  );

  fireEvent.click(screen.getByRole('button', { name: /Posting style|No style|Usual settings|This place only/ }));

  return optionNames();
};

describe('UserPostingStylePicker container candidates', () => {
  it('offers a group only its own dedicated styles and common styles', () => {
    const names = renderPicker('portable:group-column:111', { kind: 'group', key: '111' });

    expect(names.some(name => name.includes('Group A'))).toBe(true);
    expect(names.some(name => name.includes('Common'))).toBe(true);
    expect(names.some(name => name.includes('Group B'))).toBe(false);
    expect(names.some(name => name.includes('Books'))).toBe(false);
    expect(names.some(name => name.includes('News'))).toBe(false);
  });

  it('does not offer another group’s dedicated style on a hashtag', () => {
    const names = renderPicker('portable:hashtag-column:books', { kind: 'hashtag', key: 'books' });

    expect(names.some(name => name.includes('Books'))).toBe(true);
    expect(names.some(name => name.includes('Common'))).toBe(true);
    expect(names.some(name => name.includes('News'))).toBe(false);
    expect(names.some(name => name.includes('Group A'))).toBe(false);
    expect(names.some(name => name.includes('Group B'))).toBe(false);
  });

  it('keeps the compact header while the style catalog is loading or failed', () => {
    const composerId = 'portable:list-column:7';
    const base = ImmutableMap({
      composers: composers(undefined, createComposer(composerId)),
      userPostingStyles: ImmutableMap({ status: 'loading', styles: ImmutableList() }),
      relationships: ImmutableMap(),
    });
    const store = createStore(reduce, base);

    store.dispatch(applyComposerSurface(composerId, { kind: 'list', key: '7' }, null, null));

    const { rerender } = render(
      <Provider store={store}>
        <ComposerProvider composerId={composerId}>
          <UserPostingStylePicker header contextDetails={<div>Follow the group</div>} />
        </ComposerProvider>
      </Provider>,
    );

    const picker = document.querySelector('[data-posting-style-picker]');

    expect(picker).toBeTruthy();
    expect(document.querySelector('.compose-form__style-context')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /7|Posting destination|No style|This place only|Usual settings/ }));

    expect(screen.getByText('Loading posting styles')).toBeTruthy();
    expect(screen.getByText('Follow the group')).toBeTruthy();
    expect(document.querySelector('.compose-form__style-overlay')).toContainElement(screen.getByText('Follow the group'));
    expect(screen.queryByRole('menuitemradio')).toBeNull();

    const failed = store.getState().setIn(['userPostingStyles', 'status'], 'failed');

    rerender(
      <Provider store={createStore(reduce, failed)}>
        <ComposerProvider composerId={composerId}>
          <UserPostingStylePicker header contextDetails={<div>Follow the group</div>} />
        </ComposerProvider>
      </Provider>,
    );

    expect(document.querySelector('[data-posting-style-picker]')).toBeTruthy();
    expect(document.querySelector('[data-posting-style-catalog="failed"]')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Reload posting styles' })).toBeTruthy();
    expect(screen.getByText('Follow the group')).toBeTruthy();
  });

  it('offers a list only common styles', () => {
    const names = renderPicker('portable:list-column:7', { kind: 'list', key: '7' });

    expect(names.some(name => name.includes('Common'))).toBe(true);
    expect(names.some(name => name.includes('Group A'))).toBe(false);
    expect(names.some(name => name.includes('Group B'))).toBe(false);
    expect(names.some(name => name.includes('Books'))).toBe(false);
    expect(names.some(name => name.includes('News'))).toBe(false);
    expect(names.some(name => name.includes('No style'))).toBe(true);
  });
});

it('updates three open catalogs together without changing primary/portable drafts or selected snapshots', () => {
  const primary = compose(undefined, { type: '@@INIT' }).set('text', 'primary draft').setIn(['userPostingStyle', 'selectedId'], 'common').setIn(['userPostingStyle', 'snapshot'], catalog.last());
  const combined = (state, action) => state
    .set('compose', compose(state.get('compose'), action))
    .set('composers', composers(state.get('composers'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action));
  const store = createStore(combined, ImmutableMap({ compose: primary, composers: composers(undefined, createComposer('portable:A')), userPostingStyles: userPostingStyles(undefined, { type: USER_POSTING_STYLES_FETCH_SUCCESS, styles: catalog }) }));
  store.dispatch(applyComposerSurface('portable:A', { kind: 'list', key: 'a' }));
  store.dispatch(createComposer('portable:B'));
  store.dispatch(applyComposerSurface('portable:B', { kind: 'hashtag', key: 'books' }));
  const beforePrimary = store.getState().get('compose');
  const beforePortable = store.getState().get('composers');
  render(<Provider store={store}><React.Fragment>{[PRIMARY_COMPOSER_ID, 'portable:A', 'portable:B'].map(composerId => <ComposerProvider key={composerId} composerId={composerId}><UserPostingStylePicker header /></ComposerProvider>)}</React.Fragment></Provider>);
  document.querySelectorAll('.compose-form__style-button').forEach(button => fireEvent.click(button));
  act(() => store.dispatch({ type: USER_POSTING_STYLES_FETCH_SUCCESS, styles: ImmutableList([catalog.last().set('name', 'Renamed common').set('icon', '📚'), style('new', 'Added common', { kind: 'none' }), style('group-new', 'Only primary', { kind: 'group', accountId: '999' })]) }));
  expect(screen.getAllByText('Renamed common')).toHaveLength(3);
  expect(screen.getAllByText('Added common')).toHaveLength(3);
  expect(screen.getAllByText('Only primary')).toHaveLength(1);
  expect(store.getState().get('compose')).toBe(beforePrimary);
  expect(store.getState().get('composers')).toBe(beforePortable);
  act(() => store.dispatch({ type: USER_POSTING_STYLES_FETCH_SUCCESS, styles: [] }));
  expect(screen.queryByText('Renamed common')).toBeNull();
  expect(screen.queryByText('Added common')).toBeNull();
  expect(store.getState().getIn(['compose', 'userPostingStyle', 'snapshot', 'name'])).toBe('Common');
  expect(store.getState().get('compose')).toBe(beforePrimary);
  expect(store.getState().get('composers')).toBe(beforePortable);
});
