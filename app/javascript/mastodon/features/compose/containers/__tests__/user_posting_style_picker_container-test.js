import { fireEvent, render, screen } from '@testing-library/react';
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

import { USER_POSTING_STYLES_FETCH_SUCCESS } from '../../../../actions/user_posting_styles';
import { applyComposerSurface, createComposer } from '../../../../actions/composer';
import { groupPostingContext } from '../../../../posting_context/fixtures/group_context_fixture';
import composers from '../../../../reducers/composers';
import userPostingStyles from '../../../../reducers/user_posting_styles';
import { ComposerProvider } from '../../composer_id_context';
import UserPostingStylePicker from '../user_posting_style_picker_container';

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

  fireEvent.click(screen.getByRole('button', { name: /Posting style|Usual settings|This place only/ }));

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

  it('offers a list only common styles', () => {
    const names = renderPicker('portable:list-column:7', { kind: 'list', key: '7' });

    expect(names.some(name => name.includes('Common'))).toBe(true);
    expect(names.some(name => name.includes('Group A'))).toBe(false);
    expect(names.some(name => name.includes('Group B'))).toBe(false);
    expect(names.some(name => name.includes('Books'))).toBe(false);
    expect(names.some(name => name.includes('News'))).toBe(false);
    expect(names.some(name => name.includes('Usual settings'))).toBe(true);
  });
});
