/* eslint-disable react/prop-types */

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import settingsReducer from 'mastodon/reducers/settings';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ put: jest.fn(() => Promise.resolve({ data: {} })) })),
}));

jest.mock('mastodon/actions/timelines', () => ({
  expandHashtagTimeline: (...args) => ({ type: 'HASHTAG_TIMELINE_EXPAND', args }),
  clearTimeline: id => ({ type: 'TIMELINE_CLEAR', id }),
  clearTimelineSplitReturnAnchor: id => ({ type: 'TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR', id }),
  createTimelineSplit: () => ({ type: 'TIMELINE_SPLIT_CREATE' }),
  destroyTimelineSplit: () => ({ type: 'TIMELINE_SPLIT_DESTROY' }),
  saveTimelineSplitReturnAnchor: () => ({ type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR' }),
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
jest.mock('mastodon/components/column_header', () => ({ children, extraButton }) => <div>{extraButton}{children}</div>);
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

const loadTimeline = ({ isAdministrator = true, isStaff = false } = {}) => {
  let HashtagTimeline;

  jest.isolateModules(() => {
    jest.doMock('mastodon/initial_state', () => ({
      ...jest.requireActual('mastodon/initial_state'),
      isAdministrator,
      isStaff,
    }));
    HashtagTimeline = require('../index').default;
  });

  return HashtagTimeline;
};

const withVisibility = (settingsState, visibility) => {
  if (!visibility) {
    return settingsState;
  }

  return Object.keys(visibility).reduce(
    (state, composerId) => state.setIn(['portableComposerVisibility', composerId], visibility[composerId]),
    settingsState,
  );
};

const renderTimeline = (HashtagTimeline, { columnId, id = 'foo', tags, visibility, tagRecord = true } = {}) => {
  captured.length = 0;
  const initialState = ImmutableMap({
    tags: tagRecord ? ImmutableMap({ [id]: fromJS({ name: id, following: false }) }) : ImmutableMap(),
    timelines: ImmutableMap(),
    settings: withVisibility(settingsReducer(undefined, { type: '@@INIT' }), visibility),
  });
  const store = createStore((state = initialState, action) => {
    if (action.type === 'SETTING_CHANGE' || action.type === 'SETTING_SAVE') {
      return state.set('settings', settingsReducer(state.get('settings'), action));
    }

    return state;
  }, initialState, applyMiddleware(thunk));

  const view = render(
    <Provider store={store}>
      <HashtagTimeline params={{ id, tags }} columnId={columnId} multiColumn={false} />
    </Provider>,
  );

  return {
    props: captured[captured.length - 1],
    store,
    ...view,
  };
};

describe('HashtagTimeline portable composer', () => {
  afterEach(() => {
    cleanup();
  });

  it('keeps the composer hidden until an administrator shows that hashtag composer', () => {
    const HashtagTimeline = loadTimeline({ isAdministrator: true });
    const tags = {
      all: [{ value: 'bar' }],
      any: [{ value: 'baz' }],
      none: [{ value: 'qux' }],
    };
    const view = renderTimeline(HashtagTimeline, { id: 'Foo', tags });

    expect(screen.getByRole('button', { name: 'Split timeline' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Show composer' }).getAttribute('aria-pressed')).toBe('false');
    expect(view.props.prepend).toBeNull();
    expect(view.props.alwaysPrepend).toBe(false);

    fireEvent.click(screen.getByRole('button', { name: 'Show composer' }));

    const shown = captured[captured.length - 1];

    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:hashtag-route:foo'])).toBe(true);
    expect(shown.alwaysPrepend).toBe(true);
    expect(shown.prepend.props.composerId).toEqual('portable:hashtag-route:foo');
    expect(shown.prepend.key).toEqual('portable:hashtag-route:foo');
    expect(shown.prepend.props.postingContext.managed.hashtags.map(tag => tag.normalizedName)).toEqual(['foo']);
    expect(shown.prepend.props.postingContext.key).toEqual('builtin:hashtag:foo');
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Hide composer' }));

    expect(captured[captured.length - 1].prepend).toBeNull();
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:hashtag-route:foo'])).toBe(false);
  });

  it('uses the pinned column id and ignores additional filters for the same hashtag composer', () => {
    const HashtagTimeline = loadTimeline({ isAdministrator: true });
    const tags = {
      all: [{ value: 'bar' }],
      any: [{ value: 'baz' }],
      none: [{ value: 'qux' }],
    };
    const view = renderTimeline(HashtagTimeline, {
      id: 'Foo',
      columnId: 'col-1',
      tags,
      visibility: { 'portable:hashtag-column:col-1': true },
    });

    expect(view.props.prepend.props.composerId).toEqual('portable:hashtag-column:col-1');
    expect(view.props.prepend.key).toEqual('portable:hashtag-column:col-1');
    expect(view.props.prepend.props.postingContext.managed.hashtags.map(tag => tag.normalizedName)).toEqual(['foo']);

    view.rerender(
      <Provider store={view.store}>
        <HashtagTimeline params={{ id: 'Foo', tags: { any: [{ value: 'alpha' }] } }} columnId='col-1' multiColumn={false} />
      </Provider>,
    );

    const filtered = captured[captured.length - 1];

    expect(filtered.prepend.props.composerId).toEqual('portable:hashtag-column:col-1');
    expect(filtered.prepend.props.postingContext.managed.hashtags.map(tag => tag.normalizedName)).toEqual(['foo']);
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:hashtag-column:col-1'])).toBe(true);
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();
  });

  it('remembers hashtag composers independently across route changes', () => {
    const HashtagTimeline = loadTimeline({ isAdministrator: true });
    const visibility = {
      'portable:hashtag-route:ruby': true,
      'portable:hashtag-route:javascript': false,
    };
    const view = renderTimeline(HashtagTimeline, { id: 'ruby', visibility, tagRecord: false });

    expect(view.props.prepend.props.composerId).toEqual('portable:hashtag-route:ruby');

    view.rerender(
      <Provider store={view.store}>
        <HashtagTimeline params={{ id: 'javascript' }} multiColumn={false} />
      </Provider>,
    );

    expect(captured[captured.length - 1].prepend).toBeNull();
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:hashtag-route:ruby'])).toBe(true);
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:hashtag-route:javascript'])).toBe(false);

    view.rerender(
      <Provider store={view.store}>
        <HashtagTimeline params={{ id: 'ruby' }} multiColumn={false} />
      </Provider>,
    );

    expect(captured[captured.length - 1].prepend.props.composerId).toEqual('portable:hashtag-route:ruby');
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:hashtag-route:ruby'])).toBe(true);
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:hashtag-route:javascript'])).toBe(false);
  });

  it('hides the toggle and composer from a non-administrator even when visibility is saved', () => {
    const HashtagTimeline = loadTimeline({ isAdministrator: false, isStaff: true });
    const props = renderTimeline(HashtagTimeline, {
      visibility: { 'portable:hashtag-route:foo': true },
    }).props;

    expect(screen.queryByRole('button', { name: 'Show composer' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Hide composer' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();
    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });
});
