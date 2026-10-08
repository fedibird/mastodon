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
jest.mock('../../../components/column_header', () => ({ children, extraButton }) => <div>{extraButton}{children}</div>);
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

const loadTimeline = ({ isAdministrator = true, isStaff = false } = {}) => {
  let ListTimeline;

  jest.isolateModules(() => {
    jest.doMock('mastodon/initial_state', () => ({
      ...jest.requireActual('mastodon/initial_state'),
      isAdministrator,
      isStaff,
    }));
    ListTimeline = require('../index').default;
  });

  return ListTimeline;
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

const withDisplayMode = (settingsState, displayMode) => {
  if (!displayMode) {
    return settingsState;
  }

  return Object.keys(displayMode).reduce(
    (state, composerId) => state.setIn(['portableComposerDisplayMode', composerId], displayMode[composerId]),
    settingsState,
  );
};

const renderTimeline = (ListTimeline, { columnId, id = '7', visibility, displayMode } = {}) => {
  captured.length = 0;
  const initialState = ImmutableMap({
    lists: ImmutableMap({
      [id]: fromJS({ id, title: 'Friends', replies_policy: 'list' }),
    }),
    timelines: ImmutableMap(),
    settings: withDisplayMode(withVisibility(settingsReducer(undefined, { type: '@@INIT' }), visibility), displayMode),
  });
  const store = createStore((state = initialState, action) => {
    if (action.type === 'SETTING_CHANGE' || action.type === 'SETTING_SAVE') {
      return state.set('settings', settingsReducer(state.get('settings'), action));
    }

    return state;
  }, initialState, applyMiddleware(thunk));

  const view = render(
    <Provider store={store}>
      <ListTimeline params={{ id }} columnId={columnId} multiColumn={false} />
    </Provider>,
  );

  return {
    props: captured[captured.length - 1],
    store,
    ...view,
  };
};

describe('ListTimeline portable composer', () => {
  afterEach(() => {
    cleanup();
  });

  it('shows an administrator toggle and mounts the composer only while that composer is visible', () => {
    const ListTimeline = loadTimeline({ isAdministrator: true });
    const view = renderTimeline(ListTimeline);
    const toggle = screen.getByRole('button', { name: 'Show composer' });

    expect(toggle.getAttribute('aria-pressed')).toBe('false');
    expect(view.props.prepend).toBeNull();
    expect(view.props.alwaysPrepend).toBe(false);

    fireEvent.click(toggle);

    const shown = captured[captured.length - 1];

    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-route:7'])).toBe(true);
    expect(screen.getByRole('button', { name: 'Hide composer' }).getAttribute('aria-pressed')).toBe('true');
    expect(shown.alwaysPrepend).toBe(true);
    expect(shown.prepend.props.composerId).toEqual('portable:list-route:7');
    expect(shown.prepend.props.postingContext).toBeUndefined();
    expect(shown.prepend.key).toEqual('portable:list-route:7');

    fireEvent.click(screen.getByRole('button', { name: 'Hide composer' }));

    expect(captured[captured.length - 1].prepend).toBeNull();
    expect(captured[captured.length - 1].alwaysPrepend).toBe(false);
    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-route:7'])).toBe(false);
  });

  it('uses the pinned column id for a visible list composer', () => {
    const ListTimeline = loadTimeline({ isAdministrator: true });
    const props = renderTimeline(ListTimeline, {
      columnId: 'col-1',
      visibility: { 'portable:list-column:col-1': true },
    }).props;

    expect(props.alwaysPrepend).toBe(true);
    expect(props.prepend.props.composerId).toEqual('portable:list-column:col-1');
    expect(props.prepend.key).toEqual('portable:list-column:col-1');
  });

  it('keeps display mode when the composer is hidden and shown again', () => {
    const ListTimeline = loadTimeline({ isAdministrator: true });
    const view = renderTimeline(ListTimeline, {
      columnId: 'a',
      visibility: { 'portable:list-column:a': true },
      displayMode: {
        'portable:list-column:a': 'simple',
        'portable:list-column:b': 'full',
      },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Hide composer' }));
    fireEvent.click(screen.getByRole('button', { name: 'Show composer' }));

    expect(view.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-column:a'])).toBe(true);
    expect(view.store.getState().getIn(['settings', 'portableComposerDisplayMode', 'portable:list-column:a'])).toBe('simple');
    expect(view.store.getState().getIn(['settings', 'portableComposerDisplayMode', 'portable:list-column:b'])).toBe('full');
    expect(captured[captured.length - 1].prepend.props.composerId).toEqual('portable:list-column:a');
  });

  it('keeps two list composer ids independent', () => {
    const ListTimeline = loadTimeline({ isAdministrator: true });
    const visibility = {
      'portable:list-column:a': true,
      'portable:list-column:b': false,
    };
    const visible = renderTimeline(ListTimeline, { columnId: 'a', visibility });

    expect(visible.props.prepend.props.composerId).toEqual('portable:list-column:a');

    cleanup();
    const hidden = renderTimeline(ListTimeline, { columnId: 'b', visibility });

    expect(hidden.props.prepend).toBeNull();
    expect(hidden.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-column:a'])).toBe(true);
    expect(hidden.store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:list-column:b'])).toBe(false);
  });

  it('hides the toggle and composer from a non-administrator even when visibility is saved', () => {
    const ListTimeline = loadTimeline({ isAdministrator: false, isStaff: false });
    const props = renderTimeline(ListTimeline, {
      visibility: { 'portable:list-route:7': true },
    }).props;

    expect(screen.queryByRole('button', { name: 'Show composer' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Hide composer' })).toBeNull();
    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });

  it('hides the toggle and composer from staff who lack the administrator permission', () => {
    const ListTimeline = loadTimeline({ isAdministrator: false, isStaff: true });
    const props = renderTimeline(ListTimeline, {
      visibility: { 'portable:list-route:7': true },
    }).props;

    expect(screen.queryByRole('button', { name: 'Show composer' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Hide composer' })).toBeNull();
    expect(props.prepend).toBeNull();
    expect(props.alwaysPrepend).toBe(false);
  });

  it('does not let the composer toggle click reach the header', () => {
    let PortableComposerToggle;

    jest.isolateModules(() => {
      jest.doMock('mastodon/initial_state', () => ({
        ...jest.requireActual('mastodon/initial_state'),
        isAdministrator: true,
      }));
      PortableComposerToggle = require('../../compose/components/portable_composer_toggle').default;
    });

    const onToggle = jest.fn();

    render(<PortableComposerToggle visible={false} onToggle={onToggle} />);

    const button = screen.getByRole('button', { name: 'Show composer' });
    const event = new window.MouseEvent('click', { bubbles: true, cancelable: true });
    const stop = jest.spyOn(event, 'stopPropagation');

    button.dispatchEvent(event);

    expect(stop).toHaveBeenCalledTimes(1);
    expect(onToggle).toHaveBeenCalledTimes(1);
    expect(button.getAttribute('aria-pressed')).toBe('false');
  });
});
