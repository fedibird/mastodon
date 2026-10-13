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

jest.mock('../../../components/column', () => {
  const ReactMock = require('react');

  return ReactMock.forwardRef(({ children }, ref) => ReactMock.createElement('section', { ref }, children));
});

jest.mock('../../../components/column_header', () => {
  const ReactMock = require('react');

  return () => ReactMock.createElement('h1', { className: 'column-header' }, 'header');
});

import { resolveRequest } from 'mastodon/mix/adapter';
import { normalizeSource, SOURCE_TYPES } from 'mastodon/mix/source';
import { resolveStream } from 'mastodon/mix/stream_adapters';
import { MixEditorPage } from '../editor';
import SourceForm from '../components/source_form';
import SourceList from '../components/source_list';

const ja = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../locales/ja.json'), 'utf8'));
const en = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../locales/en.json'), 'utf8'));

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

const jaIntl = {
  formatMessage: (message, values) => {
    let text = ja[message.id] || message.defaultMessage;

    if (values) {
      Object.keys(values).forEach(key => {
        text = text.split(`{${key}}`).join(String(values[key]));
      });
    }

    return text;
  },
};

const acceptSource = () => true;
const emptySearch = () => Promise.resolve([]);

const renderEditor = (props) => render(
  <MemoryRouter>
    <MixEditorPage
      dispatch={jest.fn()}
      intl={intl}
      history={{ push: jest.fn() }}
      enabled
      multiColumn
      lists={[]}
      {...props}
    />
  </MemoryRouter>,
);

describe('mix source follow-up', () => {
  it('omits limited from new display sources and still accepts a saved one', () => {
    render(
      <MemoryRouter>
        <SourceForm intl={intl} lists={[]} onAddSource={acceptSource} onSearch={emptySearch} />
      </MemoryRouter>,
    );

    const values = Array.from(screen.getByLabelText('Display source type').options).map(option => option.value);

    expect(values).not.toContain('limited');
    expect(values).toContain('home');
    expect(values).toContain('personal');
    expect(SOURCE_TYPES).toContain('limited');

    const saved = normalizeSource({ type: 'limited', params: { shows: { reblog: false } } });

    expect(saved.ok).toBe(true);
    expect(resolveRequest(saved.source, null, { enableLimitedTimeline: true }).ok).toBe(true);
    expect(resolveRequest(saved.source, null, { enableLimitedTimeline: true }).path).toBe('/api/v1/timelines/home');
  });

  it('keeps a saved limited source visible while editing', () => {
    render(
      <MemoryRouter>
        <SourceList
          intl={intl}
          editable
          sources={[
            { type: 'limited', params: {} },
            { type: 'home', params: {} },
          ]}
          onRemove={jest.fn()}
          onReorder={jest.fn()}
        />
      </MemoryRouter>,
    );

    expect(screen.getByText('Limited')).toBeTruthy();
    expect(screen.getByText('Home')).toBeTruthy();
  });

  it('uses the Japanese labels without changing the stored source types', () => {
    expect(ja['mixes.source.personal']).toBe('自分限定ホーム');
    expect(ja['mixes.field.hide_limited']).toBe('サークル・相互限定を隠す');
    expect(ja['mixes.source.limited']).toBe('限定');
    expect(ja['mixes.back_to_list']).toBe('ミックスの一覧へ');
    expect(en['mixes.back_to_list']).toBe('Back to mixes');

    render(
      <MemoryRouter>
        <div>
          <SourceForm intl={jaIntl} lists={[]} onAddSource={acceptSource} onSearch={emptySearch} />
          <SourceList
            intl={jaIntl}
            sources={[{ type: 'personal', params: {} }, { type: 'limited', params: {} }]}
          />
        </div>
      </MemoryRouter>,
    );

    expect(screen.getByRole('option', { name: '自分限定ホーム' })).toBeTruthy();
    expect(screen.queryByRole('option', { name: '限定' })).toBeNull();
    expect(screen.getByLabelText('サークル・相互限定を隠す')).toBeTruthy();
    expect(screen.getByText('限定')).toBeTruthy();
  });

  it('links both the new and edit screens back to the mix list', () => {
    const created = renderEditor({});

    expect(screen.getByRole('link', { name: 'Back to mixes' }).getAttribute('href')).toBe('/mixes');
    expect(screen.getByText('A mix combines several columns into one timeline.')).toBeTruthy();
    created.unmount();

    renderEditor({
      mixId: 'mix-1',
      mix: fromJS({
        id: 'mix-1',
        title: 'Desk',
        version: 1,
        sources: [{ type: 'limited', params: {} }, { type: 'home', params: {} }],
      }),
    });

    expect(screen.getByRole('link', { name: 'Back to mixes' }).getAttribute('href')).toBe('/mixes');
    expect(screen.getByDisplayValue('Desk')).toBeTruthy();
    expect(screen.getByText('Limited')).toBeTruthy();
  });

  it('still narrows a group source by its saved tag', () => {
    const group = normalizeSource({ type: 'group', id: '8', params: { tagged: '#News' } });

    expect(group.ok).toBe(true);
    expect(group.source.params.tagged).toBe('news');
    expect(resolveStream(group.source)).toMatchObject({
      params: { id: '8', tagged: 'news' },
    });
  });
});
