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

import { MixTimelinePage, mixTimelineMode } from '../timeline';

const intl = {
  formatMessage: (message) => message.defaultMessage,
};

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
          enabled
          multiColumn
        />
      </MemoryRouter>,
    );

    expect(screen.getByRole('heading', { name: 'Desk' })).toBeTruthy();
    expect(screen.getByText('Friends')).toBeTruthy();
    expect(screen.getByText('This address opens your own mix. It does not share the feed with anyone else.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'pin' }));

    expect(dispatch).toHaveBeenCalledWith(expect.any(Function));
    const thunk = dispatch.mock.calls[0][0];
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
});
