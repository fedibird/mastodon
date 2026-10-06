/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
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

jest.mock('mastodon/actions/timelines', () => ({
  expandHashtagTimeline: (...args) => ({ type: 'HASHTAG_TIMELINE_EXPAND', args }),
  clearTimeline: id => ({ type: 'TIMELINE_CLEAR', id }),
}));

jest.mock('mastodon/actions/streaming', () => ({
  connectHashtagStream: () => () => () => {},
}));

jest.mock('mastodon/actions/tags', () => ({
  fetchHashtag: id => ({ type: 'HASHTAG_FETCH', id }),
  followHashtag: id => ({ type: 'HASHTAG_FOLLOW', id }),
  unfollowHashtag: id => ({ type: 'HASHTAG_UNFOLLOW', id }),
}));

jest.mock('mastodon/components/column', () => {
  const React = require('react');
  return React.forwardRef(({ children }, ref) => <div ref={ref}>{children}</div>);
});
jest.mock('mastodon/components/column_header', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../../compose/portable_composer', () => {
  const React = require('react');

  return function PortableComposer ({ composerId, postingContext }) {
    const names = ((postingContext && postingContext.managed && postingContext.managed.hashtags) || []).map(tag => tag.normalizedName);

    return <div data-testid='portable-composer' data-composer-id={composerId} data-managed={names.join(' ')} />;
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
  let HashtagTimeline;

  jest.isolateModules(() => {
    jest.doMock('mastodon/initial_state', () => ({
      ...jest.requireActual('mastodon/initial_state'),
      new_features_policy: policy,
    }));
    HashtagTimeline = require('../index').default;
  });

  return HashtagTimeline;
};

const renderTimeline = (HashtagTimeline, { columnId, id = 'foo', tags } = {}) => {
  captured.length = 0;
  const store = createStore(() => ImmutableMap({
    tags: ImmutableMap(),
    timelines: ImmutableMap(),
    settings: ImmutableMap({
      columns: ImmutableList(),
      hashtag: ImmutableMap(),
    }),
  }), applyMiddleware(thunk));

  render(
    <Provider store={store}>
      <HashtagTimeline params={{ id, tags }} columnId={columnId} multiColumn={false} />
    </Provider>,
  );

  return captured[captured.length - 1];
};

describe('HashtagTimeline portable composer', () => {
  it('prepends a tester composer for the primary hashtag only', () => {
    const HashtagTimeline = loadTimeline('tester');
    const tags = {
      all: [{ value: 'bar' }],
      any: [{ value: 'baz' }],
      none: [{ value: 'qux' }],
    };
    const routeProps = renderTimeline(HashtagTimeline, { id: 'Foo', tags });
    const columnProps = renderTimeline(HashtagTimeline, { id: 'Foo', columnId: 'col-1', tags });

    expect(routeProps.alwaysPrepend).toBe(true);
    expect(routeProps.prepend.props.composerId).toEqual('portable:hashtag-route:foo');
    expect(routeProps.prepend.key).toEqual('portable:hashtag-route:foo');
    expect(routeProps.prepend.props.postingContext.managed.hashtags.map(tag => tag.normalizedName)).toEqual(['foo']);
    expect(routeProps.prepend.props.postingContext.key).toEqual('builtin:hashtag:foo');
    expect(columnProps.prepend.props.composerId).toEqual('portable:hashtag-column:col-1');
    expect(columnProps.prepend.key).toEqual('portable:hashtag-column:col-1');
    expect(columnProps.prepend.props.postingContext.managed.hashtags.map(tag => tag.normalizedName)).toEqual(['foo']);
  });

  it('does not prepend a composer for default or conservative policy', () => {
    ['default', 'conservative'].forEach(policy => {
      const HashtagTimeline = loadTimeline(policy);
      const props = renderTimeline(HashtagTimeline);

      expect(props.prepend).toBeNull();
      expect(props.alwaysPrepend).toBe(false);
    });
  });
});
