import { render } from '@testing-library/react';
import { List as ImmutableList } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: () => null,
}));

jest.mock('../regeneration_indicator', () => () => null);
jest.mock('../load_gap', () => () => null);
jest.mock('../reload_zone', () => () => null);

jest.mock('../scrollable_list', () => {
  const ReactMock = require('react');

  return ({ children }) => ReactMock.createElement('div', null, children);
});

jest.mock('../../containers/status_container', () => {
  const ReactMock = require('react');

  return (props) => ReactMock.createElement('article', {
    'data-badges': props.sourceBadges ? 'yes' : 'no',
  });
});

import StatusList from '../status_list';

const store = createStore(state => state || {});
const homeBadges = () => [{ key: 'home', label: 'Home' }];

describe('status list mix badges', () => {
  it('omits source badges unless the timeline provides them', () => {
    const { container, rerender } = render(
      <Provider store={store}>
        <StatusList scrollKey='home' statusIds={ImmutableList(['1'])} />
      </Provider>,
    );

    expect(container.querySelector('article').getAttribute('data-badges')).toBe('no');

    rerender(
      <Provider store={store}>
        <StatusList
          scrollKey='mix'
          statusIds={ImmutableList(['1'])}
          sourceBadgesForId={homeBadges}
        />
      </Provider>,
    );

    expect(container.querySelector('article').getAttribute('data-badges')).toBe('yes');
  });
});
