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
import { buildHashtagTimelinePostingContext } from '../../../../posting_context/hashtag';
import compose from '../../../../reducers/compose';
import composers from '../../../../reducers/composers';
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
});
