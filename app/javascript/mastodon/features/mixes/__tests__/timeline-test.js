import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { MemoryRouter } from 'react-router-dom';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

jest.mock('../../../components/column_header', () => {
  const ReactMock = require('react');

  const ColumnHeader = (props) => (
    ReactMock.createElement('div', null,
      ReactMock.createElement('h1', null, props.title),
      props.onPin && ReactMock.createElement('button', { type: 'button', onClick: props.onPin }, props.pinned ? 'unpin' : 'pin'),
    )
  );

  return ColumnHeader;
});

jest.mock('../../../components/column', () => {
  const ReactMock = require('react');

  return ReactMock.forwardRef(({ children, label }, ref) => (
    ReactMock.createElement('section', { ref, 'aria-label': label }, children)
  ));
});

jest.mock('../../../components/status_list', () => {
  const ReactMock = require('react');

  return (props) => ReactMock.createElement('div', null, props.prepend);
});

import { MixTimelinePage, mixTimelineMode } from '../timeline';

const intl = {
  formatMessage: (message, values) => {
    let text = message.defaultMessage;

    if (values) {
      Object.keys(values).forEach(key => {
        text = text.split(`{${key}}`).join(String(values[key]));
      });
    }

    return text;
  },
};

const savedMix = fromJS({
  id: 'mix-1',
  title: 'Desk',
  version: 1,
  sources: [
    { type: 'home', params: {} },
    { type: 'public', params: {} },
  ],
});

describe('mix timeline column', () => {
  it('distinguishes loading states for an unavailable, deleted, and saved mix', () => {
    expect(mixTimelineMode({ enabled: false, mix: null })).toBe('unavailable');
    expect(mixTimelineMode({ enabled: true, mix: null })).toBe('deleted');
    expect(mixTimelineMode({ enabled: true, mix: fromJS({ id: 'mix-1' }) })).toBe('ready');
  });

  it('pins the mix id without using it as the column uuid', () => {
    const dispatch = jest.fn();
    const mix = fromJS({
      id: 'mix-1',
      title: 'Desk',
      version: 1,
      sources: [
        { type: 'home', params: {} },
        { type: 'list', id: '4', title: 'Friends', params: {} },
      ],
    });

    render(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={dispatch}
          intl={intl}
          mixId='mix-1'
          mix={mix}
          columnKey='column:pinned'
          enabled
          multiColumn
        />
      </MemoryRouter>,
    );

    expect(screen.getByRole('heading', { name: 'Desk' })).toBeTruthy();
    expect(screen.getByText('This address opens your own mix. It does not share the feed with anyone else.')).toBeTruthy();
    const beforePin = dispatch.mock.calls.length;

    fireEvent.click(screen.getByRole('button', { name: 'pin' }));

    const thunk = dispatch.mock.calls[beforePin][0];
    const inner = jest.fn();

    thunk(inner);
    expect(inner).toHaveBeenCalledWith({
      type: 'COLUMN_ADD',
      id: 'MIX',
      params: { id: 'mix-1' },
    });
  });

  it('unpins one column uuid and leaves the mix definition alone', () => {
    const dispatch = jest.fn();

    render(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={dispatch}
          intl={intl}
          columnId='column-uuid'
          mixId='mix-1'
          mix={fromJS({ id: 'mix-1', title: 'Desk', version: 1, sources: [{ type: 'home', params: {} }, { type: 'public', params: {} }] })}
          enabled
          multiColumn
        />
      </MemoryRouter>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'unpin' }));
    const thunk = dispatch.mock.calls[0][0];
    const inner = jest.fn();

    thunk(inner);
    expect(inner).toHaveBeenCalledWith({
      type: 'COLUMN_REMOVE',
      uuid: 'column-uuid',
    });
  });

  it('shows a deleted mix without rendering another mix', () => {
    render(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={jest.fn()}
          intl={intl}
          mixId='missing'
          mix={null}
          enabled
        />
      </MemoryRouter>,
    );

    expect(screen.getByText('This mix was deleted.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'pin' })).toBeNull();
  });

  it('closes the previous column when the column key changes', () => {
    const dispatch = jest.fn();
    const { rerender } = render(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={dispatch}
          intl={intl}
          mixId='mix-1'
          mix={savedMix}
          columnKey='column:a'
          signature='home'
          enabled
          multiColumn
        />
      </MemoryRouter>,
    );

    dispatch.mockClear();
    rerender(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={dispatch}
          intl={intl}
          mixId='mix-1'
          mix={savedMix}
          columnKey='column:b'
          signature='home'
          enabled
          multiColumn
        />
      </MemoryRouter>,
    );

    expect(dispatch).toHaveBeenCalledWith({ type: 'MIX_TIMELINE_CLOSE', columnKey: 'column:a' });
    expect(dispatch.mock.calls.some(call => typeof call[0] === 'function')).toBe(true);
  });

  it('discards fetch state when the mix definition is removed', () => {
    const dispatch = jest.fn();
    const { rerender } = render(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={dispatch}
          intl={intl}
          mixId='mix-1'
          mix={savedMix}
          columnKey='route:mix-1'
          signature='home'
          enabled
        />
      </MemoryRouter>,
    );

    dispatch.mockClear();
    rerender(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={dispatch}
          intl={intl}
          mixId='mix-1'
          mix={null}
          columnKey='route:mix-1'
          signature=''
          enabled
        />
      </MemoryRouter>,
    );

    expect(dispatch).toHaveBeenCalledWith({ type: 'MIX_TIMELINE_CLOSE', columnKey: 'route:mix-1' });
    expect(dispatch.mock.calls.filter(call => typeof call[0] === 'function')).toHaveLength(1);
    expect(screen.getByText('This mix was deleted.')).toBeTruthy();
  });

  it('identifies a partly loaded source and retries only that source key', () => {
    const dispatch = jest.fn();

    render(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={dispatch}
          intl={intl}
          mixId='mix-1'
          mix={savedMix}
          columnKey='column:partial'
          enabled
          multiColumn
          view={{
            statusIds: fromJS(['500']),
            contextById: {},
            warningsById: {},
            orderGuaranteed: false,
            waiting: false,
            hasMore: false,
            running: false,
            suspended: [{ key: 'source-public', label: 'Federated' }],
            errors: [
              { key: 'source-remote', error: 'server', label: 'Remote' },
              { key: 'source-limited', error: 'rate_limit', label: 'Limited', retryAt: Date.now() + 60000 },
            ],
          }}
        />
      </MemoryRouter>,
    );

    expect(screen.getByText('Federated is only partly loaded.')).toBeTruthy();
    expect(screen.queryByText('Some sources failed, so this order may be incomplete.')).toBeNull();
    expect(screen.getByRole('button', { name: 'Retry source-public' }).getAttribute('data-source-key')).toBe('source-public');
    expect(screen.getByRole('button', { name: 'Retry source-remote' }).getAttribute('data-source-key')).toBe('source-remote');
    expect(screen.queryByRole('button', { name: 'Retry source-limited' })).toBeNull();

    const beforeRetry = dispatch.mock.calls.length;

    fireEvent.click(screen.getByRole('button', { name: 'Retry source-public' }));

    expect(dispatch.mock.calls.slice(beforeRetry).map(call => typeof call[0])).toEqual(['function']);
  });

  it('says an account source is not live until it is refreshed', () => {
    render(
      <MemoryRouter>
        <MixTimelinePage
          dispatch={jest.fn()}
          intl={intl}
          mixId='mix-1'
          mix={savedMix}
          columnKey='column:account'
          enabled
          multiColumn
          view={{
            statusIds: fromJS([]),
            contextById: {},
            warningsById: {},
            orderGuaranteed: true,
            waiting: false,
            hasMore: false,
            running: false,
            suspended: [],
            errors: [],
            degraded: [],
            restOnly: [{ key: 'account-key', label: 'ada' }],
          }}
        />
      </MemoryRouter>,
    );

    expect(screen.getByText('ada is not live. Refresh to check for new posts.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Refresh account-key' }).getAttribute('data-source-key')).toBe('account-key');
  });
});
