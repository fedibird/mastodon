import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { MemoryRouter } from 'react-router-dom';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

import { MixList } from '../index';

const intl = {
  formatMessage: (message) => message.defaultMessage,
};

const renderList = (props) => render(
  <MemoryRouter>
    <MixList
      intl={intl}
      mixes={fromJS([])}
      enabled
      {...props}
    />
  </MemoryRouter>,
);

describe('mix list', () => {
  it('links each mix to its timeline and editor without offering the feature when disabled', () => {
    renderList({
      mixes: fromJS([
        { id: 'mix-1', title: 'Desk', version: 1, sources: [] },
      ]),
    });

    expect(screen.getByRole('link', { name: 'Desk' }).getAttribute('href')).toBe('/timelines/mixes/mix-1');
    expect(screen.getByRole('link', { name: 'Edit mix' }).getAttribute('href')).toBe('/mixes/mix-1/edit');
    expect(screen.getByRole('link', { name: 'New mix' }).getAttribute('href')).toBe('/mixes/new');
  });

  it('hides saved mixes from viewers who cannot use the feature', () => {
    renderList({
      enabled: false,
      mixes: fromJS([{ id: 'mix-1', title: 'Desk', version: 1, sources: [] }]),
    });

    expect(screen.getByText('Mix is available to administrators and beta testers.')).toBeTruthy();
    expect(screen.queryByRole('link', { name: 'Desk' })).toBeNull();
  });
});
