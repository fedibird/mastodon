import fs from 'fs';
import path from 'path';

import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import * as asyncComponents from 'mastodon/features/ui/util/async-components';
import EmojiPickerShell from '../emoji_picker_shell';
import { loadStandardEmojiPicker, resetStandardEmojiPickerLoaderForTests } from '../standard_emoji_loader';

jest.mock('react-intl', () => {
  const intl = { formatMessage: descriptor => descriptor.defaultMessage };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

const javascriptRoot = path.resolve(__dirname, '../../../..');
const personalRoots = [
  'mastodon/features/emoji/emoji_stock.js',
  'mastodon/features/emoji/emoji_stock_source.js',
  'mastodon/features/emoji/stock_emoji_picker.js',
];
const shellRoots = [
  ...personalRoots,
  'mastodon/features/emoji/emoji_picker_shell.js',
  'mastodon/features/emoji/standard_emoji_loader.js',
];

const IMPORT_RE = /(?:import|export)[\s\S]*?\sfrom\s*['"]([^'"]+)['"]|import\s*['"]([^'"]+)['"]|require\(\s*['"]([^'"]+)['"]\s*\)/g;
const DYNAMIC_RE = /import\(\s*(?:\/\*[\s\S]*?\*\/\s*)?['"]([^'"]+)['"]\s*\)/g;

const forbidden = /emoji-mart|@emoji-mart|emoji_mart_|emoji_utils|emoji_unicode_mapping|sheet_15|custom_emojis|actions\/emojis|(?:^|\/)emoji_picker$|(?:^|\/)emoji$/;

const read = relative => fs.readFileSync(path.join(javascriptRoot, relative), 'utf8');

const resolveLocal = (fromFile, spec) => {
  let base = null;

  if (spec.startsWith('.')) {
    base = path.resolve(path.dirname(fromFile), spec);
  } else if (spec.startsWith('mastodon/')) {
    base = path.join(javascriptRoot, spec);
  }

  if (!base) {
    return null;
  }

  const candidates = [base, `${base}.js`, path.join(base, 'index.js')];

  return candidates.find(candidate => fs.existsSync(candidate) && fs.statSync(candidate).isFile()) || null;
};

const specifiers = (source, pattern) => {
  const found = [];

  source.replace(pattern, (match, first, second, third) => {
    found.push(first || second || third);
    return match;
  });

  return found;
};

const walkStatic = roots => {
  const seen = new Set();
  const dynamic = [];
  const external = [];

  const visit = file => {
    if (!file || seen.has(file)) {
      return;
    }

    seen.add(file);
    const source = fs.readFileSync(file, 'utf8');

    specifiers(source, DYNAMIC_RE).forEach(spec => dynamic.push({ file, spec }));
    specifiers(source, IMPORT_RE).forEach(spec => {
      const local = resolveLocal(file, spec);

      if (local) {
        visit(local);
      } else {
        external.push({ file, spec });
      }
    });
  };

  roots.forEach(relative => visit(path.join(javascriptRoot, relative)));

  return { files: [...seen], dynamic, external };
};

describe('personal picker dependency boundary', () => {
  it('keeps the personal picker off the standard catalog, sprite, and custom emoji API', () => {
    const personal = walkStatic(personalRoots);
    const shell = walkStatic(shellRoots);
    const personalHits = [
      ...personal.external.map(entry => entry.spec),
      ...personal.dynamic.map(entry => entry.spec),
    ].filter(spec => forbidden.test(spec));
    const shellStaticHits = shell.external.map(entry => entry.spec).filter(spec => forbidden.test(spec));
    const ownDynamic = shell.dynamic
      .filter(entry => entry.file.includes(`${path.sep}features${path.sep}emoji${path.sep}`))
      .map(entry => entry.spec);

    expect(personalHits).toEqual([]);
    expect(shellStaticHits).toEqual([]);
    expect(ownDynamic).toEqual([]);
    expect(read('mastodon/features/emoji/stock_emoji_picker.js')).not.toContain('sheet_15');
    expect(read('mastodon/features/emoji/emoji_stock.js')).not.toContain('sheet_15');
    expect(read('mastodon/features/emoji/emoji_stock_source.js')).not.toContain('fetch(');
    expect(read('mastodon/features/ui/util/async-components.js')).toContain('/* webpackChunkName: "emoji_picker" */\'../../emoji/emoji_picker\'');
    expect(read('mastodon/features/emoji/standard_emoji_loader.js')).toContain('asyncComponents.EmojiPicker');
    expect(read('mastodon/features/emoji/standard_emoji_loader.js')).not.toContain('emoji-mart');

    [
      'mastodon/features/compose/components/emoji_picker_dropdown.js',
      'mastodon/components/reaction_picker_dropdown.js',
      'mastodon/features/ui/components/reaction_modal.js',
      'mastodon/features/emoji/form_emoji_picker.js',
      'mastodon/initial_state.js',
    ].forEach(relative => {
      const source = read(relative);

      expect(source).not.toContain('emoji_picker_shell');
      expect(source).not.toContain('stock_emoji_picker');
      expect(source).not.toContain('loadDisconnectedEmojiStock');
      expect(source).not.toContain('prefer_personal_emoji');
    });
  });
});

describe('shell connected to the standard entry', () => {
  beforeEach(() => {
    resetStandardEmojiPickerLoaderForTests();
    jest.spyOn(asyncComponents, 'EmojiPicker');
    global.fetch = jest.fn();
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('does not import the standard module for personal display, search, or selection', async () => {
    const stock = {
      categories: [
        {
          id: 'saved',
          name: 'Saved',
          items: [
            {
              key: 'saved-1',
              label: 'Saved wave',
              image: { src: 'https://assets.example/wave.svg', alt: '👋' },
              search: ['Saved wave', 'wave'],
              selection: { id: 'wave', custom: false, native: '👋' },
            },
          ],
        },
      ],
    };
    const onPick = jest.fn();

    function stockSource() {
      return Promise.resolve({ status: 'ready', stock });
    }

    render(
      <EmojiPickerShell
        initialMode='personal'
        stockSource={stockSource}
        onPick={onPick}
      />,
    );

    const search = await screen.findByRole('searchbox');

    fireEvent.change(search, { target: { value: 'missing' } });
    expect(await screen.findByText('No matching emojis found')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Clear' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Saved wave' }));

    expect(onPick).toHaveBeenCalledWith({ id: 'wave', custom: false, native: '👋' }, expect.any(Object));
    expect(asyncComponents.EmojiPicker).not.toHaveBeenCalled();
    expect(global.fetch).not.toHaveBeenCalled();
    expect(document.body.innerHTML).not.toContain('sheet_15');
    expect(Array.prototype.slice.call(document.querySelectorAll('img')).map(img => img.getAttribute('src'))).toEqual(['https://assets.example/wave.svg']);
    expect(Object.keys(require.cache).some(file => /emoji-mart|emoji_mart_nimble_data|emoji_utils/.test(file))).toBe(false);

    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));

    await waitFor(() => expect(asyncComponents.EmojiPicker).toHaveBeenCalledTimes(1));

    const loaded = await loadStandardEmojiPicker();
    const entry = await import('../emoji_picker');

    expect(loaded.Picker).toBe(entry.Picker);
    expect(loaded.Emoji).toBe(entry.Emoji);
    expect(global.fetch).not.toHaveBeenCalled();
  });
});
