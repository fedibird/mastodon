import fs from 'fs';
import path from 'path';

import { render, screen } from '@testing-library/react';
import React from 'react';

const localeDir = path.join(__dirname, '../../../../locales');
const en = JSON.parse(fs.readFileSync(path.join(localeDir, 'en.json'), 'utf8'));
const ja = JSON.parse(fs.readFileSync(path.join(localeDir, 'ja.json'), 'utf8'));

const keys = [
  'compose_form.posting_style.context',
  'compose_form.destination.details',
  'compose_form.destination.warning',
];

jest.mock('react-intl', () => {
  const fs = require('fs');
  const path = require('path');
  const jaMessages = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'app/javascript/mastodon/locales/ja.json'), 'utf8'));
  const intl = {
    formatMessage: ({ id, defaultMessage }) => (Object.prototype.hasOwnProperty.call(jaMessages, id) ? jaMessages[id] : defaultMessage),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

import ComposerDestinationSummary from '../composer_destination_summary';

const orderedKeys = (filename) => {
  const text = fs.readFileSync(path.join(localeDir, filename), 'utf8');
  const keysInFile = text.match(/^\s*"((?:\\.|[^"\\])*)"\s*:/gm).map(line => line.match(/"((?:\\.|[^"\\])*)"/)[1]);
  const duplicates = keysInFile.filter((key, index) => keysInFile.indexOf(key) !== index);

  return { keysInFile, duplicates };
};

describe('composer destination locales', () => {
  it('adds the destination strings once, in key order, in English and Japanese', () => {
    expect(en['compose_form.posting_style.context']).toBe('Posting destination');
    expect(en['compose_form.destination.details']).toBe('Destination details');
    expect(en['compose_form.destination.warning']).toBe('Posting to this destination needs attention');
    expect(ja['compose_form.posting_style.context']).toBe('投稿先');
    expect(ja['compose_form.destination.details']).toBe('投稿先の詳細');
    expect(ja['compose_form.destination.warning']).toBe('投稿先への投稿に確認が必要です');

    keys.forEach((key) => {
      expect(ja[key]).not.toBe(en[key]);
    });

    ['en.json', 'ja.json'].forEach((filename) => {
      const { keysInFile, duplicates } = orderedKeys(filename);

      expect(duplicates).toEqual([]);
      keys.forEach((key) => {
        const index = keysInFile.indexOf(key);

        expect(index).toBeGreaterThan(0);
        expect(keysInFile.lastIndexOf(key)).toBe(index);
        expect(keysInFile[index - 1] < key).toBe(true);
        expect(key < keysInFile[index + 1]).toBe(true);
      });
    });
  });

  it('renders Japanese catalog strings instead of the English defaults', () => {
    render(
      <ComposerDestinationSummary
        placeLabel=''
        warning
        contextDetails={<span>投稿先コンテキスト</span>}
      />,
    );

    expect(screen.getByText('投稿先')).toBeTruthy();
    expect(screen.getByRole('button', { name: '投稿先の詳細' })).toBeTruthy();
    expect(screen.getByRole('status')).toHaveTextContent('投稿先への投稿に確認が必要です');
    expect(screen.queryByText('Posting destination')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Destination details' })).toBeNull();
    expect(screen.queryByText('Posting to this destination needs attention')).toBeNull();
  });
});
