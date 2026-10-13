import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />,
}));

import { changeComposeSearchability, changeComposeVisibility, COMPOSE_REPLY } from '../../../../actions/compose';
import { createComposer, targetComposerAction } from '../../../../actions/composer';
import composer, { initialState as initialComposerState } from '../../../../reducers/composer';
import composers from '../../../../reducers/composers';
import { PRIMARY_COMPOSER_ID } from '../../../../utils/composer';
import { ComposerProvider } from '../../composer_id_context';
import SearchabilityIndicatorContainer from '../searchability_indicator_container';

const PORTABLE_ID = 'portable:1';

const root = (state = ImmutableMap({ compose: initialComposerState }), action) => {
  const composerId = action.meta && action.meta.composerId;

  if (composerId && composerId !== PRIMARY_COMPOSER_ID) {
    return state.set('composers', composers(state.get('composers'), action));
  }

  return state.set('compose', composer(state.get('compose'), action));
};

const directStatus = () => ImmutableMap({
  id: 'status-1',
  visibility: 'direct',
  spoiler_text: '',
  url: 'https://example.test/1',
  mentions: ImmutableList(),
});

const widen = (store, composerId) => {
  store.dispatch(targetComposerAction(changeComposeVisibility('direct'), composerId));
  store.dispatch(targetComposerAction(changeComposeSearchability('private'), composerId));
};

const renderIndicators = (store) => render(
  <Provider store={store}>
    <div data-testid='primary-search'>
      <ComposerProvider composerId={PRIMARY_COMPOSER_ID}>
        <SearchabilityIndicatorContainer />
      </ComposerProvider>
    </div>
    <div data-testid='portable-search'>
      <ComposerProvider composerId={PORTABLE_ID}>
        <SearchabilityIndicatorContainer />
      </ComposerProvider>
    </div>
  </Provider>,
);

const indicatorIn = (testId) => screen.getByTestId(testId).querySelector('[data-testid="searchability-indicator"]');

describe('SearchabilityIndicatorContainer', () => {
  it('shows a cancellable change when searchability matches the widened privacy', () => {
    const store = createStore(root, applyMiddleware(thunk));

    store.dispatch(createComposer(PORTABLE_ID));
    store.dispatch(targetComposerAction({
      type: COMPOSE_REPLY,
      status: directStatus(),
      context_references: [],
    }, PORTABLE_ID));
    widen(store, PRIMARY_COMPOSER_ID);
    renderIndicators(store);

    const primary = store.getState().get('compose');

    expect(primary.get('privacy')).toBe('private');
    expect(primary.get('searchability')).toBe('private');
    expect(primary.get('privacy_before_searchability')).toBe('direct');
    expect(indicatorIn('primary-search').textContent).toContain('Followers-only');
    expect(indicatorIn('portable-search')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Reset search visibility' }));

    const restored = store.getState().get('compose');
    const portable = store.getState().getIn(['composers', 'byId', PORTABLE_ID]);

    expect(restored.get('privacy')).toBe('direct');
    expect(restored.get('searchability')).toBe('direct');
    expect(restored.get('privacy_before_searchability')).toBeNull();
    expect(indicatorIn('primary-search')).toBeNull();
    expect(indicatorIn('portable-search')).toBeNull();
    expect(portable.get('privacy')).toBe('direct');
    expect(portable.get('searchability')).toBe('direct');
    expect(portable.get('privacy_before_searchability')).toBeNull();
  });

  it('resets only the composer whose indicator was closed', () => {
    const store = createStore(root, applyMiddleware(thunk));

    store.dispatch(createComposer(PORTABLE_ID));
    widen(store, PRIMARY_COMPOSER_ID);
    widen(store, PORTABLE_ID);
    renderIndicators(store);

    expect(indicatorIn('primary-search')).toBeTruthy();
    expect(indicatorIn('portable-search')).toBeTruthy();

    fireEvent.click(screen.getByTestId('primary-search').querySelector('button'));

    const primary = store.getState().get('compose');
    const portable = store.getState().getIn(['composers', 'byId', PORTABLE_ID]);

    expect(primary.get('privacy')).toBe('direct');
    expect(primary.get('searchability')).toBe('direct');
    expect(indicatorIn('primary-search')).toBeNull();
    expect(portable.get('privacy')).toBe('private');
    expect(portable.get('searchability')).toBe('private');
    expect(portable.get('privacy_before_searchability')).toBe('direct');
    expect(indicatorIn('portable-search').textContent).toContain('Followers-only');
  });
});
