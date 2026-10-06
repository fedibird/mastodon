import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { combineReducers } from 'redux-immutable';

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

import { changeCompose } from '../../../../actions/compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../../../../actions/composer';
import { groupPostingContext } from '../../../../posting_context/__tests__/group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../../../../posting_context/hashtag';
import compose from '../../../../reducers/compose';
import composers from '../../../../reducers/composers';
import relationships from '../../../../reducers/relationships';
import { ComposerProvider } from '../../composer_id_context';
import PostingContextBarContainer from '../../containers/posting_context_bar_container';

const composerId = 'composer-a';

const renderBar = (store) => render(
  <Provider store={store}>
    <ComposerProvider composerId={composerId}>
      <PostingContextBarContainer />
    </ComposerProvider>
  </Provider>,
);

describe('PostingContextBar', () => {
  it('toggles an advisory hashtag without rewriting the raw draft', () => {
    const store = createStore(combineReducers({ compose, composers }));

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, buildHashtagTimelinePostingContext('foo')));
    store.dispatch(targetComposerAction(changeCompose('Hello #foo'), composerId));

    renderBar(store);

    expect(screen.getByText('Posting context')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Do not add #foo' }));

    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Hello #foo');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'context', 'suppressions', 'hashtags']).includes('foo')).toBe(true);
    expect(screen.getByRole('button', { name: 'Include #foo' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Include #foo' }));

    expect(store.getState().getIn(['composers', 'byId', composerId, 'context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Hello #foo');
  });

  it('renders nothing when the composer has no managed hashtags', () => {
    const store = createStore(combineReducers({ compose, composers }));

    renderBar(store);

    expect(screen.queryByText('Posting context')).toBeNull();
  });

  it('shows a required group mention without a removal control', () => {
    const store = createStore(combineReducers({ compose, composers, relationships }));
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, groupPostingContext));
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: false, requested: false }],
    });

    renderBar(store);

    expect(screen.getByText('Required mention: @group')).toBeTruthy();
    expect(screen.getByText('Visibility: Public or Unlisted')).toBeTruthy();
    expect(screen.getByText('Follow @group to post in this group')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /@group/ })).toBeNull();
    expect(screen.getByText('Follow @group to post in this group').className).toContain('compose-form__posting-context-warning');

    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: false, requested: true }],
    });
    expect(screen.getByText('Follow request to @group is pending')).toBeTruthy();

    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });
    expect(screen.getByText('✓ Following @group')).toBeTruthy();
    expect(screen.queryByText('Follow @group to post in this group')).toBeNull();
  });
});
