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
        { id: 'mix-1', title: 'Desk', version: 1, sources: [{ type: 'home' }, { type: 'domain', domain: 'mstdn.jp' }, { type: 'public' }] },
      ]),
    });

    const open = screen.getByRole('link', { name: /Desk/ });
    const edit = screen.getByRole('link', { name: 'Edit mix' });

    expect(open.getAttribute('href')).toBe('/timelines/mixes/mix-1');
    expect(open.textContent).toContain('3 sources in one timeline');
    expect(edit.getAttribute('href')).toBe('/mixes/mix-1/edit');
    expect(edit.querySelector('.fa-pencil')).toBeTruthy();
    expect(edit.textContent.trim()).toBe('');
    const intro = screen.getByText('A mix combines several columns into one timeline.');
    const create = screen.getByRole('link', { name: 'New mix' });

    expect(intro.compareDocumentPosition(create) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(create.getAttribute('href')).toBe('/mixes/new');
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
