import { render } from '@testing-library/react';
import { fromJS, List as ImmutableList } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: () => null,
}));

jest.mock('../regeneration_indicator', () => () => null);
jest.mock('../load_gap', () => {
  const ReactMock = require('react');
  return () => ReactMock.createElement('div', { 'data-gap': 'true' });
});
jest.mock('../reload_zone', () => () => null);

jest.mock('../scrollable_list', () => {
  const ReactMock = require('react');
  return ({ children }) => ReactMock.createElement('div', { 'data-testid': 'media-list' }, children);
});

jest.mock('../../containers/status_container', () => {
  const ReactMock = require('react');
  return props => ReactMock.createElement('article', {
    'data-id': props.id,
    'data-media-index': props.mediaIndex,
    'data-layout-mode': props.layoutMode,
  });
});

import StatusList from '../status_list';

const store = createStore(state => state || {});
const statuses = fromJS({
  '10': { media_attachments: [{ id: 'a', type: 'image' }, { id: 'b', type: 'video' }] },
  '20': { media_attachments: [] },
  '30': { reblog: '10', media_attachments: [] },
});

describe('StatusList media display', () => {
  it('renders one row for each attachment, none for text-only posts', () => {
    const { container } = render(
      <Provider store={store}>
        <StatusList scrollKey='home' statusIds={ImmutableList(['10', '20', '30'])} mediaStatuses={statuses} layoutMode='media' />
      </Provider>,
    );

    const items = Array.from(container.querySelectorAll('article'));
    expect(items.map(item => [item.dataset.id, item.dataset.mediaIndex])).toEqual([
      ['10', '0'], ['10', '1'], ['30', '0'], ['30', '1'],
    ]);
    expect(items.every(item => item.dataset.layoutMode === 'media')).toBe(true);
  });

  it('keeps the conventional status-per-row representation in normal and card modes', () => {
    const { container, rerender } = render(
      <Provider store={store}>
        <StatusList scrollKey='home' statusIds={ImmutableList(['10', '20'])} layoutMode='normal' />
      </Provider>,
    );

    expect(Array.from(container.querySelectorAll('article')).map(item => item.dataset.id)).toEqual(['10', '20']);

    rerender(
      <Provider store={store}>
        <StatusList scrollKey='home' statusIds={ImmutableList(['10', '20'])} layoutMode='card-2' />
      </Provider>,
    );
    expect(Array.from(container.querySelectorAll('article')).map(item => item.dataset.id)).toEqual(['10', '20']);
  });
});
