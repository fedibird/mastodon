import fs from 'fs';
import path from 'path';

import React from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';

// Jest does not transform emoji-mart's ESM build. This stand-in matches the
// real Nimble search field: autoFocus focuses on mount only, not on a later
// prop change. The shell still renders the real Picker adapter.
jest.mock('emoji-mart/dist-es/components/picker/nimble-picker', () => {
  const ReactInsideMock = require('react');

  class NimblePicker extends ReactInsideMock.Component {

    componentDidMount() {
      if (this.props.autoFocus && this.node) {
        this.node.focus();
      }
    }

    setRef = node => {
      this.node = node;
    };

    render() {
      return ReactInsideMock.createElement('input', {
        placeholder: 'Search',
        'aria-label': 'Standard search',
        ref: this.setRef,
      });
    }

  }

  NimblePicker.propTypes = {
    autoFocus: (props, propName) => {
      const value = props[propName];

      if (value === undefined || value === null || typeof value === 'boolean') {
        return null;
      }

      return new Error('autoFocus');
    },
  };

  return NimblePicker;
});

jest.mock('emoji-mart/dist-es/components/emoji/nimble-emoji', () => () => null);
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
    expect(read('mastodon/features/emoji/emoji_stock_source.js')).toContain('/api/v1/emoji_sets/personal/stock');
    expect(read('mastodon/features/emoji/emoji_stock_source.js')).not.toContain('/api/v1/custom_emojis');
    expect(read('mastodon/features/ui/util/async-components.js')).toContain('/* webpackChunkName: "emoji_picker" */\'../../emoji/emoji_picker\'');
    expect(read('mastodon/features/emoji/standard_emoji_loader.js')).toContain('asyncComponents.EmojiPicker');
    expect(read('mastodon/features/emoji/standard_emoji_loader.js')).not.toContain('emoji-mart');

    [
      'mastodon/features/compose/components/emoji_picker_dropdown.js',
      'mastodon/components/reaction_picker_dropdown.js',
      'mastodon/features/ui/components/reaction_modal.js',
    ].forEach(relative => {
      const source = read(relative);

      expect(source).toContain('emoji_picker_panel');
      expect(source).not.toContain('emoji_picker_shell');
      expect(source).not.toContain('stock_emoji_picker');
      expect(source).not.toContain('loadDisconnectedEmojiStock');
      expect(source).not.toContain('EmojiPickerAsync');
      expect(source).not.toContain('emoji-mart');
    });

    const form = read('mastodon/features/emoji/form_emoji_picker.js');
    const initialState = read('mastodon/initial_state.js');

    expect(form).not.toContain('emoji_picker_shell');
    expect(form).not.toContain('emoji-mart');
    expect(form).toContain('preloadStandardEmojiPickerIfNeeded');
    expect(initialState).not.toContain('emoji_picker_shell');
    expect(initialState).toContain('emoji_picker_prefer_personal');
    expect(initialState).toContain('emoji_picker_lazy_load_standard');
    expect(read('mastodon/containers/mastodon.js')).not.toContain('fetchCustomEmojis');
    expect(read('mastodon/containers/compose_container.js')).not.toContain('fetchCustomEmojis');
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

  it('focuses the real standard search again when the shell is reopened', async () => {
    const entry = await import('../emoji_picker');
    const caller = document.createElement('button');

    caller.textContent = 'Caller';
    document.body.appendChild(caller);

    function loadReady() {
      return Promise.resolve({ Picker: entry.Picker, Emoji: entry.Emoji });
    }

    function onPick() {}

    const view = render(
      <EmojiPickerShell
        open
        initialMode='standard'
        personalEnabled={false}
        loadStandardEmojiPicker={loadReady}
        onPick={onPick}
        returnFocusElement={caller}
      />,
    );

    await waitFor(() => expect(document.activeElement).toHaveAttribute('placeholder', 'Search'));
    view.rerender(
      <EmojiPickerShell
        open={false}
        initialMode='standard'
        personalEnabled={false}
        loadStandardEmojiPicker={loadReady}
        onPick={onPick}
        returnFocusElement={caller}
      />,
    );
    caller.focus();
    expect(document.activeElement).toBe(caller);
    view.rerender(
      <EmojiPickerShell
        open
        initialMode='standard'
        personalEnabled={false}
        loadStandardEmojiPicker={loadReady}
        onPick={onPick}
        returnFocusElement={caller}
      />,
    );
    await waitFor(() => expect(document.activeElement).toHaveAttribute('placeholder', 'Search'));
    caller.remove();
  });

  it('does not move focus into a real standard picker that loads behind the active search', async () => {
    const entry = await import('../emoji_picker');
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
              search: ['Saved wave'],
              selection: { id: 'wave', custom: false, native: '👋' },
            },
          ],
        },
      ],
    };
    let resolveStandard;

    function stockSource() {
      return Promise.resolve({ status: 'ready', stock });
    }

    function loadLater() {
      return new Promise(resolve => {
        resolveStandard = resolve;
      });
    }

    function onPick() {}

    render(
      <EmojiPickerShell
        initialMode='personal'
        standardEnabled={false}
        stockSource={stockSource}
        loadStandardEmojiPicker={loadLater}
        onPick={onPick}
      />,
    );

    const personalSearch = await screen.findByRole('searchbox');

    await waitFor(() => expect(document.activeElement).toBe(personalSearch));
    render(
      <EmojiPickerShell
        initialMode='standard'
        personalEnabled={false}
        loadStandardEmojiPicker={loadLater}
        onPick={onPick}
      />,
    );
    expect(await screen.findByText('Loading standard emoji')).toBeInTheDocument();
    personalSearch.blur();
    personalSearch.focus();
    fireEvent.keyDown(personalSearch, { key: 'a' });

    await act(async () => {
      resolveStandard({ Picker: entry.Picker, Emoji: entry.Emoji });
    });

    expect(await screen.findByPlaceholderText('Search')).toBeInTheDocument();
    expect(document.activeElement).toBe(personalSearch);
  });
});
