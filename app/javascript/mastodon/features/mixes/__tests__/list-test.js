import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import fs from 'fs';
import path from 'path';
import React from 'react';
import { MemoryRouter } from 'react-router-dom';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

import { MixList } from '../index';

const ja = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../locales/ja.json'), 'utf8'));

const format = (catalog) => (message, values) => {
  let text = (catalog && catalog[message.id]) || message.defaultMessage;

  if (values) {
    Object.keys(values).forEach(key => {
      text = text.split(`{${key}}`).join(String(values[key]));
    });
  }

  return text;
};

const intl = { formatMessage: format() };
const jaIntl = { formatMessage: format(ja) };

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

const labelsIn = (container) => Array.from(container.querySelectorAll('.mix-list__source-label')).map(node => node.textContent);

describe('mix list', () => {
  it('shows saved sources in order and keeps timeline and settings as separate links', () => {
    const { container } = renderList({
      mixes: fromJS([
        {
          id: 'mix-1',
          title: 'Desk',
          version: 1,
          sources: [
            { type: 'home', params: {} },
            { type: 'domain', domain: 'mstdn.jp', params: {} },
            { type: 'hashtag', id: 'fedibird', params: {} },
            { type: 'list', id: '4', params: {} },
            { type: 'group', id: '8', title: 'Newsroom', params: {} },
            { type: 'account', id: '9', params: {} },
          ],
        },
      ]),
      lists: fromJS({ 4: { id: '4', title: 'Friends' } }),
      accounts: fromJS({ 9: { id: '9', display_name: 'Ada', acct: 'ada@example.com' } }),
    });

    const open = screen.getByRole('link', { name: /Desk/ });
    const settings = screen.getByRole('link', { name: 'Mix settings' });

    expect(labelsIn(container)).toEqual(['Home', 'mstdn.jp', '#fedibird', 'Friends', 'Newsroom', 'Ada']);
    expect(open.getAttribute('href')).toBe('/timelines/mixes/mix-1');
    expect(open.contains(container.querySelector('.mix-list__sources'))).toBe(true);
    expect(open.contains(settings)).toBe(false);
    expect(settings.getAttribute('href')).toBe('/mixes/mix-1/edit');
    expect(settings.getAttribute('title')).toBe('Mix settings');
    expect(settings.getAttribute('aria-label')).toBe('Mix settings');
    expect(settings.querySelector('.fa-sliders')).toBeTruthy();
    expect(settings.querySelector('.fa-pencil')).toBeNull();
    expect(screen.queryByText(/sources in one timeline/)).toBeNull();
    expect(container.querySelectorAll('.mix-list__source a, .mix-list__source button')).toHaveLength(0);

    const intro = screen.getByText('A mix combines several columns into one timeline.');
    const create = screen.getByRole('link', { name: 'New mix' });

    expect(intro.compareDocumentPosition(create) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(create.getAttribute('href')).toBe('/mixes/new');
  });

  it('uses the Japanese personal label and still shows a saved limited source', () => {
    const { container } = renderList({
      intl: jaIntl,
      mixes: fromJS([{
        id: 'mix-ja',
        title: '手元',
        version: 1,
        sources: [
          { type: 'personal', params: {} },
          { type: 'limited', params: {} },
        ],
      }]),
    });

    expect(labelsIn(container)).toEqual(['自分限定ホーム', '限定']);
    expect(screen.getByRole('link', { name: 'ミックスの設定' }).getAttribute('href')).toBe('/mixes/mix-ja/edit');
    expect(container.textContent).not.toContain('ソースをまとめたタイムライン');
  });

  it('shows all eight saved sources and skips one that cannot be described', () => {
    const sources = [1, 2, 3, 4, 5, 6, 7, 8].map(index => ({
      type: 'domain',
      domain: `node${index}.example`,
      params: {},
    }));

    sources.splice(3, 0, { type: 'not-a-source', params: {} });

    const { container } = renderList({
      mixes: fromJS([{ id: 'mix-8', title: 'Wide', version: 1, sources }]),
    });

    expect(labelsIn(container)).toEqual([1, 2, 3, 4, 5, 6, 7, 8].map(index => `node${index}.example`));
    expect(screen.getByRole('link', { name: /Wide/ }).getAttribute('href')).toBe('/timelines/mixes/mix-8');
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
