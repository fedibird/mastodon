/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../../actions/lists', () => ({
  fetchList: id => ({ type: 'LIST_FETCH', id }),
  deleteList: id => ({ type: 'LIST_DELETE', id }),
  updateList: (...args) => ({ type: 'LIST_UPDATE', args }),
}));

jest.mock('../../../actions/timelines', () => ({
  expandListTimeline: id => ({ type: 'LIST_TIMELINE_EXPAND', id }),
}));

jest.mock('../../../actions/streaming', () => ({
  connectListStream: () => () => () => {},
}));

jest.mock('../../../components/missing_indicator', () => () => null);
jest.mock('../../../components/loading_indicator', () => () => null);
jest.mock('../../../components/column', () => {
  const React = require('react');
  return React.forwardRef(({ children }, ref) => <div ref={ref}>{children}</div>);
});
jest.mock('../../../components/column_back_button', () => () => null);
jest.mock('../../../components/column_header', () => ({ children }) => <div>{children}</div>);
jest.mock('../../../components/icon', () => () => null);
jest.mock('../../../components/radio_button', () => () => null);
jest.mock('../../compose/portable_composer', () => {
  const React = require('react');

  return function PortableComposer ({ composerId }) {
    return <div data-testid='portable-composer' data-composer-id={composerId} />;
  };
});

const captured = [];

jest.mock('../../ui/containers/status_list_container', () => {
  const React = require('react');

  return function StatusListContainer (props) {
    captured.push(props);
    return <div data-testid='status-list'>{props.prepend}</div>;
  };
});

const loadTimeline = (policy) => {
  let ListTimeline;

  jest.isolateModules(() => {
    jest.doMock('mastodon/initial_state', () => ({
      ...jest.requireActual('mastodon/initial_state'),
      new_features_policy: policy,
    }));
    ListTimeline = require('../index').default;
  });

  return ListTimeline;
};

const renderTimeline = (ListTimeline, { columnId, id = '7' } = {}) => {
  captured.length = 0;
  const store = createStore(() => ImmutableMap({
    lists: ImmutableMap({
      [id]: fromJS({ id, title: 'Friends', replies_policy: 'list' }),
    }),
    settings: ImmutableMap({
      columns: ImmutableList(),
      list: ImmutableMap(),
    }),
  }), applyMiddleware(thunk));

  render(
    <Provider store={store}>
      <ListTimeline params={{ id }} columnId={columnId} multiColumn={false} />
    </Provider>,
  );

  return captured[captured.length - 1];
};

describe('ListTimeline portable composer', () => {
  it('prepends a list composer for tester policy', () => {
    const ListTimeline = loadTimeline('tester');
    const routeProps = renderTimeline(ListTimeline);
    const columnProps = renderTimeline(ListTimeline, { columnId: 'col-1' });

    expect(routeProps.alwaysPrepend).toBe(true);
    expect(routeProps.prepend.props.composerId).toEqual('portable:list-route:7');
    expect(routeProps.prepend.key).toEqual('portable:list-route:7');
    expect(columnProps.prepend.props.composerId).toEqual('portable:list-column:col-1');
    expect(columnProps.prepend.key).toEqual('portable:list-column:col-1');
  });

  it('does not prepend a composer for default or conservative policy', () => {
    ['default', 'conservative'].forEach(policy => {
      const ListTimeline = loadTimeline(policy);
      const props = renderTimeline(ListTimeline);

      expect(props.prepend).toBeNull();
      expect(props.alwaysPrepend).toBe(false);
    });
  });
});
