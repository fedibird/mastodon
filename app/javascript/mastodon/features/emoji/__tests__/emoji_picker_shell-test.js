/* eslint-disable react/prop-types */

import React from 'react';
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { useEmoji } from 'mastodon/actions/emojis';
import EmojiPickerShell from '../emoji_picker_shell';

jest.mock('react-intl', () => {
  const intl = { formatMessage: descriptor => descriptor.defaultMessage };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

jest.mock('mastodon/actions/emojis', () => ({
  useEmoji: jest.fn(),
}));

const SKIN = '👍\u{1F3FB}';
const ZWJ = '👩\u200d👩\u200d👦\u200d👦';
const VARIATION = '#\uFE0F\u20E3';

const deepFreeze = value => {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) {
    return value;
  }

  Object.keys(value).forEach(key => deepFreeze(value[key]));
  return Object.freeze(value);
};

const fixture = () => deepFreeze({
  categories: [
    {
      id: 'cat-z',
      name: 'Zebra',
      items: [
        {
          key: 'place-zwj',
          label: 'Family',
          image: { src: 'https://assets.example/family.svg', alt: ZWJ, title: ':family:' },
          search: ['Family', 'かぞく', ZWJ],
          selection: { id: 'woman-woman-boy-boy', custom: false, native: ZWJ },
        },
        {
          key: 'place-skin',
          label: 'Thumb light',
          image: { src: 'https://assets.example/thumb-light.svg', alt: SKIN, title: ':+1:' },
          search: ['Thumb light', '+1', 'いいね'],
          selection: { id: '+1', custom: false, native: SKIN },
        },
      ],
    },
    {
      id: 'cat-a',
      name: 'Apple',
      items: [
        {
          key: 'place-plain',
          label: 'Thumb',
          image: { src: 'https://assets.example/thumb.svg', alt: '👍' },
          search: ['Thumb', '+1'],
          selection: { id: '+1', custom: false, native: '👍' },
        },
        {
          key: 'place-custom',
          label: 'Fedibird',
          image: {
            src: 'https://cdn.example/fedibird-static.png',
            animatedSrc: 'https://cdn.example/fedibird.gif',
            alt: ':fedibird@example.com:',
            title: 'fedibird',
          },
          search: ['Fedibird', ':fedibird@example.com:'],
          selection: {
            id: 'fedibird@example.com',
            custom: true,
            colons: ':fedibird@example.com:',
            native: ':fedibird@example.com:',
          },
        },
        {
          key: 'place-zwj-again',
          label: 'Family again',
          image: { src: 'https://assets.example/family.svg', alt: ZWJ },
          search: ['Family again', ZWJ],
          selection: { id: 'woman-woman-boy-boy', custom: false, native: ZWJ },
        },
        {
          key: 'place-hash',
          label: 'Hash',
          image: { src: 'https://assets.example/hash.svg', alt: VARIATION },
          search: ['Hash', VARIATION],
          selection: { id: 'hash', custom: false, native: VARIATION },
        },
      ],
    },
  ],
});

const ready = stock => () => Promise.resolve({ status: 'ready', stock });

const selected = selector => Array.prototype.slice.call(document.querySelectorAll(selector));

const deferred = () => {
  const box = {};

  box.promise = new Promise((resolve, reject) => {
    box.resolve = resolve;
    box.reject = reject;
  });

  return box;
};

class StandardProbe extends React.PureComponent {

  componentDidMount() {
    if (this.props.autoFocus && this.node) {
      this.node.focus();
    }
  }

  setRef = node => {
    this.node = node;
  };

  handleClick = event => {
    this.props.onClick({ id: 'pineapple', native: '🍍', custom: false }, event);
  };

  render() {
    return (
      <div data-testid='standard-picker'>
        <input aria-label='Standard search' ref={this.setRef} />
        <button type='button' aria-label='Standard pineapple' onClick={this.handleClick}>pineapple</button>
      </div>
    );
  }

}

const renderShell = (props = {}) => {
  const loadStandardEmojiPicker = props.loadStandardEmojiPicker || jest.fn(() => new Promise(() => {}));
  const stockSource = props.stockSource || ready(fixture());
  const onPick = props.onPick || jest.fn();
  const onRequestClose = props.onRequestClose || jest.fn();
  const view = render(
    <EmojiPickerShell
      stockSource={stockSource}
      loadStandardEmojiPicker={loadStandardEmojiPicker}
      onPick={onPick}
      onRequestClose={onRequestClose}
      {...props}
    />,
  );

  return { ...view, loadStandardEmojiPicker, stockSource, onPick, onRequestClose };
};

describe('emoji picker shell and personal stock', () => {
  beforeEach(() => {
    useEmoji.mockClear();
    global.fetch = jest.fn();
  });

  it('renders registered order only and returns fresh callback payloads', async () => {
    const stock = fixture();
    const modifiers = [];
    const onPick = jest.fn((emoji, event) => {
      modifiers.push({ ctrlKey: event.ctrlKey, metaKey: event.metaKey, key: event.key });
    });
    const { loadStandardEmojiPicker } = renderShell({
      stockSource: ready(stock),
      onPick,
      perLine: 2,
      returnFocusElement: null,
    });

    expect(await screen.findByRole('button', { name: 'Family' })).toBeInTheDocument();
    const labels = screen.getAllByText(/Zebra|Apple/).filter(node => node.className !== 'emoji-mart-anchor' && node.closest('.emoji-mart-category-label')).map(node => node.textContent);
    const keys = screen.getAllByRole('button').map(node => node.getAttribute('data-stock-key')).filter(Boolean);

    expect(labels).toEqual(['Zebra', 'Apple']);
    expect(keys).toEqual([
      'place-zwj',
      'place-skin',
      'place-plain',
      'place-custom',
      'place-zwj-again',
      'place-hash',
    ]);
    expect(selected('.emoji-stock-picker img').map(img => img.getAttribute('src'))).toEqual([
      'https://assets.example/family.svg',
      'https://assets.example/thumb-light.svg',
      'https://assets.example/thumb.svg',
      'https://cdn.example/fedibird-static.png',
      'https://assets.example/family.svg',
      'https://assets.example/hash.svg',
    ]);
    expect(document.body.innerHTML).not.toContain('sheet_15');
    expect(screen.queryByText(/frequently/i)).not.toBeInTheDocument();
    expect(screen.queryByText('People')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /skin tone/i })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Thumb light' }));
    fireEvent.click(screen.getByRole('button', { name: 'Thumb light' }));

    expect(onPick).toHaveBeenCalledTimes(2);
    expect(onPick.mock.calls[0][0]).toEqual({ id: '+1', custom: false, native: SKIN });
    expect(onPick.mock.calls[1][0]).toEqual({ id: '+1', custom: false, native: SKIN });
    expect(onPick.mock.calls[0][0]).not.toBe(onPick.mock.calls[1][0]);
    onPick.mock.calls[0][0].native = 'changed';
    onPick.mock.calls[0][0].id = 'place-skin';
    expect(stock.categories[0].items[1].selection).toEqual({ id: '+1', custom: false, native: SKIN });
    expect(stock.categories[1].items[0].selection.native).toBe('👍');

    fireEvent.click(screen.getByRole('button', { name: 'Family' }));
    fireEvent.click(screen.getByRole('button', { name: 'Family again' }));
    fireEvent.click(screen.getByRole('button', { name: 'Hash' }));
    fireEvent.click(screen.getByRole('button', { name: 'Fedibird' }), { ctrlKey: true });

    expect(onPick.mock.calls[2][0].native).toBe(ZWJ);
    expect(onPick.mock.calls[3][0].native).toBe(ZWJ);
    expect(onPick.mock.calls[2][0]).not.toBe(onPick.mock.calls[3][0]);
    expect(onPick.mock.calls[4][0].native).toBe(VARIATION);
    expect(onPick.mock.calls[5][0]).toEqual({
      id: 'fedibird@example.com',
      custom: true,
      native: ':fedibird@example.com:',
      colons: ':fedibird@example.com:',
    });
    expect(modifiers[5]).toEqual(expect.objectContaining({ ctrlKey: true, metaKey: false }));
    expect(loadStandardEmojiPicker).not.toHaveBeenCalled();
    expect(global.fetch).not.toHaveBeenCalled();
    expect(useEmoji).not.toHaveBeenCalled();
    expect(screen.queryByTestId('standard-picker')).not.toBeInTheDocument();
  });

  it('keeps search matches inside the stock and in registered order', async () => {
    const stock = fixture();
    const { loadStandardEmojiPicker } = renderShell({ stockSource: ready(stock) });
    const search = await screen.findByRole('searchbox');

    fireEvent.change(search, { target: { value: '  THUMB  ' } });

    expect(screen.getAllByRole('button').map(node => node.getAttribute('data-stock-key')).filter(Boolean)).toEqual([
      'place-skin',
      'place-plain',
    ]);

    fireEvent.change(search, { target: { value: 'pineapple' } });

    expect(await screen.findByText('No matching emojis found')).toBeInTheDocument();
    expect(document.querySelector('.emoji-mart-emoji')).toBeNull();
    expect(screen.queryByText('No emoji in this set')).not.toBeInTheDocument();
    expect(stock.categories[0].items).toHaveLength(2);
    expect(loadStandardEmojiPicker).not.toHaveBeenCalled();
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it('uses the animated image only when animation is enabled', async () => {
    const { rerender, stockSource, loadStandardEmojiPicker, onPick, onRequestClose } = renderShell({ animate: false });

    expect((await screen.findByRole('button', { name: 'Fedibird' })).querySelector('img')).toHaveAttribute('src', 'https://cdn.example/fedibird-static.png');

    rerender(
      <EmojiPickerShell
        animate
        stockSource={stockSource}
        loadStandardEmojiPicker={loadStandardEmojiPicker}
        onPick={onPick}
        onRequestClose={onRequestClose}
      />,
    );

    expect((await screen.findByRole('button', { name: 'Fedibird' })).querySelector('img')).toHaveAttribute('src', 'https://cdn.example/fedibird.gif');
  });

  it('distinguishes loading, empty, and failed stock without opening the standard picker', async () => {
    const pending = deferred();
    const stockSource = jest.fn(() => pending.promise);
    const loadStandardEmojiPicker = jest.fn(() => new Promise(() => {}));
    const view = renderShell({ stockSource, loadStandardEmojiPicker });

    expect(await screen.findByText('Loading emojis')).toBeInTheDocument();
    expect(screen.queryByText('No emoji in this set')).not.toBeInTheDocument();
    expect(screen.queryByText('Could not load emojis')).not.toBeInTheDocument();

    await act(async () => {
      pending.resolve({ status: 'ready', stock: { categories: [] } });
    });

    expect(await screen.findByText('No emoji in this set')).toBeInTheDocument();
    expect(loadStandardEmojiPicker).not.toHaveBeenCalled();
    expect(document.querySelector('img')).toBeNull();

    view.unmount();

    const failing = jest.fn()
      .mockImplementationOnce(() => Promise.resolve({ status: 'error', error: new Error('offline') }))
      .mockImplementationOnce(() => Promise.resolve({ status: 'ready', stock: fixture() }));

    renderShell({ stockSource: failing, loadStandardEmojiPicker });

    expect(await screen.findByText('Could not load emojis')).toBeInTheDocument();
    expect(screen.queryByText('No emoji in this set')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByRole('button', { name: 'Family' })).toBeInTheDocument();
    expect(failing).toHaveBeenCalledTimes(2);
    expect(loadStandardEmojiPicker).not.toHaveBeenCalled();
  });

  it('loads the standard module only after an explicit switch', async () => {
    const pending = deferred();
    const stockSource = jest.fn(ready(fixture()));
    const loadStandardEmojiPicker = jest.fn(() => pending.promise);
    renderShell({
      initialMode: 'standard',
      stockSource,
      loadStandardEmojiPicker,
    });

    expect(await screen.findByText('Loading standard emoji')).toBeInTheDocument();
    expect(stockSource).not.toHaveBeenCalled();
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));
    expect(await screen.findByRole('button', { name: 'Family' })).toBeInTheDocument();

    await act(async () => {
      pending.resolve({ Picker: StandardProbe, Emoji: () => null });
    });

    expect(screen.getByRole('button', { name: 'Personal set' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.queryByTestId('standard-picker')).not.toBeInTheDocument();
    expect(document.activeElement).not.toHaveAttribute('aria-label', 'Standard search');
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
  });

  it('focuses a standard picker that is still current and can retry after failure', async () => {
    const loadStandardEmojiPicker = jest.fn()
      .mockImplementationOnce(() => Promise.reject(new Error('offline')))
      .mockImplementationOnce(() => Promise.resolve({ Picker: StandardProbe, Emoji: () => null }));
    const seen = [];
    const onPick = (emoji, event) => {
      seen.push({ id: emoji.id, native: emoji.native, custom: emoji.custom, type: event.type, ctrlKey: event.ctrlKey });
    };
    renderShell({
      initialMode: 'standard',
      personalEnabled: false,
      loadStandardEmojiPicker,
      onPick,
    });

    expect(await screen.findByText('Could not load the standard emoji picker')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    expect(await screen.findByTestId('standard-picker')).toBeInTheDocument();
    await waitFor(() => expect(document.activeElement).toHaveAttribute('aria-label', 'Standard search'));
    fireEvent.click(screen.getByRole('button', { name: 'Standard pineapple' }));
    expect(seen).toEqual([{ id: 'pineapple', native: '🍍', custom: false, type: 'click', ctrlKey: false }]);
    expect(useEmoji).not.toHaveBeenCalled();
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(2);
  });

  it('does not reopen, restyle, or steal focus after close, unmount, or another picker', async () => {
    const outside = document.createElement('button');

    outside.textContent = 'Outside';
    document.body.appendChild(outside);
    outside.focus();

    const firstLoad = deferred();

    function loadFirst() {
      return firstLoad.promise;
    }
    const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
    const first = renderShell({
      initialMode: 'standard',
      loadStandardEmojiPicker: loadFirst,
      returnFocusElement: outside,
    });

    expect(await screen.findByText('Loading standard emoji')).toBeInTheDocument();
    first.rerender(
      <EmojiPickerShell
        open={false}
        initialMode='standard'
        loadStandardEmojiPicker={loadFirst}
        onPick={first.onPick}
        onRequestClose={first.onRequestClose}
        returnFocusElement={outside}
      />,
    );
    expect(screen.queryByText('Loading standard emoji')).not.toBeInTheDocument();

    const secondStock = {
      categories: [
        {
          id: 'other',
          name: 'Other',
          items: [
            {
              key: 'other-1',
              label: 'Other star',
              image: { src: 'https://assets.example/star.svg', alt: '⭐' },
              search: ['Other star'],
              selection: { id: 'star', custom: false, native: '⭐' },
            },
          ],
        },
      ],
    };
    renderShell({ stockSource: ready(secondStock), loadStandardEmojiPicker: jest.fn(() => new Promise(() => {})) });
    const secondSearch = await screen.findByRole('searchbox');

    await waitFor(() => expect(document.activeElement).toBe(secondSearch));

    await act(async () => {
      firstLoad.resolve({ Picker: StandardProbe, Emoji: () => null });
    });

    expect(screen.queryByTestId('standard-picker')).not.toBeInTheDocument();
    expect(document.activeElement).toBe(secondSearch);
    expect(screen.getByRole('button', { name: 'Other star' })).toBeInTheDocument();

    const thirdLoad = deferred();
    const loadThird = () => thirdLoad.promise;
    const third = renderShell({
      initialMode: 'standard',
      loadStandardEmojiPicker: loadThird,
    });

    expect(await screen.findByText('Loading standard emoji')).toBeInTheDocument();
    third.unmount();

    await act(async () => {
      thirdLoad.resolve({ Picker: StandardProbe, Emoji: () => null });
      await Promise.resolve();
    });

    const warnings = errors.mock.calls.filter(args => /setState|unmounted/i.test(args.map(String).join(' ')));

    expect(warnings).toEqual([]);
    expect(document.activeElement).toBe(secondSearch);
    errors.mockRestore();
    outside.remove();
  });

  it('keeps search and selection apart for two personal pickers', async () => {
    const first = renderShell({ stockSource: ready(fixture()) });
    const secondStock = {
      categories: [
        {
          id: 'solo',
          name: 'Solo',
          items: [
            {
              key: 'solo-1',
              label: 'Solo moon',
              image: { src: 'https://assets.example/moon.svg', alt: '🌙' },
              search: ['Solo moon'],
              selection: { id: 'crescent_moon', custom: false, native: '🌙' },
            },
          ],
        },
      ],
    };
    const second = renderShell({
      stockSource: ready(secondStock),
      loadStandardEmojiPicker: jest.fn(() => new Promise(() => {})),
    });

    const searches = await screen.findAllByRole('searchbox');

    fireEvent.change(searches[0], { target: { value: 'family' } });

    expect(within(first.container).getAllByRole('button', { name: /Family/ })).toHaveLength(2);
    expect(within(second.container).getByRole('button', { name: 'Solo moon' })).toBeInTheDocument();
    expect(within(second.container).queryByRole('button', { name: 'Family' })).not.toBeInTheDocument();
    expect(first.loadStandardEmojiPicker).not.toHaveBeenCalled();
    expect(second.loadStandardEmojiPicker).not.toHaveBeenCalled();
  });

  it('moves by keyboard and touch once, and restores the caller focus', async () => {
    const caller = document.createElement('button');

    caller.textContent = 'Compose';
    document.body.appendChild(caller);
    const modifiers = [];
    const onPick = jest.fn((emoji, event) => {
      modifiers.push({ id: emoji.id, native: emoji.native, key: event.key, ctrlKey: event.ctrlKey });
    });
    const onRequestClose = jest.fn();

    renderShell({
      onPick,
      onRequestClose,
      returnFocusElement: caller,
      perLine: 2,
      loadStandardEmojiPicker: jest.fn(() => new Promise(() => {})),
    });

    const search = await screen.findByRole('searchbox');

    await waitFor(() => expect(document.activeElement).toBe(search));
    fireEvent.keyDown(search, { key: 'ArrowDown' });
    expect(document.activeElement).toHaveAttribute('data-stock-key', 'place-zwj');
    fireEvent.keyDown(document.activeElement, { key: 'ArrowRight' });
    expect(document.activeElement).toHaveAttribute('data-stock-key', 'place-skin');
    fireEvent.keyDown(document.activeElement, { key: 'Enter' });

    expect(onPick).toHaveBeenCalledTimes(1);
    expect(modifiers[0]).toEqual(expect.objectContaining({ id: '+1', native: SKIN, key: 'Enter', ctrlKey: false }));
    expect(onRequestClose).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(caller);

    caller.blur();
    search.focus();
    fireEvent.keyDown(search, { key: 'Escape' });
    expect(onRequestClose).toHaveBeenCalledTimes(2);
    expect(document.activeElement).toBe(caller);

    const skin = screen.getByRole('button', { name: 'Thumb light' });

    fireEvent.touchEnd(skin);
    fireEvent.click(skin);
    expect(onPick).toHaveBeenCalledTimes(2);
    expect(onPick.mock.calls[1][0].native).toBe(SKIN);
    expect(useEmoji).not.toHaveBeenCalled();
    caller.remove();
  });

  it('ignores IME composition keys and selects the focused emoji after Tab', async () => {
    const modifiers = [];
    const onPick = jest.fn((emoji, event) => {
      modifiers.push({ id: emoji.id, native: emoji.native, key: event.key });
    });
    const onRequestClose = jest.fn();

    renderShell({ onPick, onRequestClose, perLine: 2 });

    const search = await screen.findByRole('searchbox');

    search.focus();
    fireEvent.keyDown(search, { key: 'Enter', isComposing: true });
    fireEvent.keyDown(search, { key: 'ArrowDown', isComposing: true });
    fireEvent.keyDown(search, { key: 'Escape', isComposing: true, keyCode: 229 });

    expect(onPick).not.toHaveBeenCalled();
    expect(onRequestClose).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(search);

    fireEvent.keyDown(search, { key: 'ArrowDown' });
    const first = document.activeElement;
    const second = screen.getAllByRole('button').filter(button => button.getAttribute('data-stock-key'))[1];

    second.focus();
    fireEvent.keyDown(second, { key: 'Enter' });

    expect(first.getAttribute('data-stock-key')).toBe('place-zwj');
    expect(modifiers).toEqual([expect.objectContaining({ id: '+1', native: SKIN, key: 'Enter' })]);
    expect(onPick).toHaveBeenCalledTimes(1);
  });

  it('keeps the same search field focused when the result list becomes empty', async () => {
    renderShell();

    const search = await screen.findByRole('searchbox');

    search.focus();
    fireEvent.change(search, { target: { value: 'zzzz-none' } });

    expect(await screen.findByText('No matching emojis found')).toBeInTheDocument();
    expect(search.isConnected).toBe(true);
    expect(document.activeElement).toBe(search);

    fireEvent.change(search, { target: { value: 'zzzz-none-x' } });
    expect(search.value).toBe('zzzz-none-x');
    expect(document.activeElement).toBe(search);
  });

  it('closes once from Escape on the mode switch while the standard picker is loading', async () => {
    const onRequestClose = jest.fn();

    renderShell({
      initialMode: 'standard',
      onRequestClose,
      loadStandardEmojiPicker: () => new Promise(() => {}),
    });

    const mode = await screen.findByRole('button', { name: 'Personal set' });

    mode.focus();
    fireEvent.keyDown(mode, { key: 'Escape' });
    fireEvent.keyDown(mode, { key: 'Escape' });

    expect(onRequestClose).toHaveBeenCalledTimes(2);
    expect(screen.queryByRole('button', { name: 'Family' })).not.toBeInTheDocument();
  });

  it('focuses a reopened standard picker from the mount autoFocus flag', async () => {
    const caller = document.createElement('button');

    caller.textContent = 'Caller';
    document.body.appendChild(caller);

    function loadStandardEmojiPicker() {
      return Promise.resolve({ Picker: StandardProbe, Emoji: () => null });
    }

    const onPick = jest.fn();
    const view = renderShell({
      open: true,
      initialMode: 'standard',
      personalEnabled: false,
      loadStandardEmojiPicker,
      onPick,
      returnFocusElement: caller,
    });

    await waitFor(() => expect(document.activeElement).toHaveAttribute('aria-label', 'Standard search'));
    view.rerender(
      <EmojiPickerShell
        open={false}
        initialMode='standard'
        personalEnabled={false}
        loadStandardEmojiPicker={loadStandardEmojiPicker}
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
        loadStandardEmojiPicker={loadStandardEmojiPicker}
        onPick={onPick}
        returnFocusElement={caller}
      />,
    );
    await waitFor(() => expect(document.activeElement).toHaveAttribute('aria-label', 'Standard search'));
    caller.remove();
  });

  it('does not steal focus when a background standard load finishes', async () => {
    renderShell();

    const personalSearch = await screen.findByRole('searchbox');
    const pending = deferred();

    function loadLater() {
      return pending.promise;
    }

    renderShell({
      initialMode: 'standard',
      personalEnabled: false,
      loadStandardEmojiPicker: loadLater,
    });
    expect(await screen.findByText('Loading standard emoji')).toBeInTheDocument();
    personalSearch.blur();
    personalSearch.focus();
    fireEvent.keyDown(personalSearch, { key: 'a' });

    await act(async () => {
      pending.resolve({ Picker: StandardProbe, Emoji: () => null });
    });

    expect(await screen.findByLabelText('Standard search')).toBeInTheDocument();
    expect(document.activeElement).toBe(personalSearch);
  });

  it('sizes stock images from emojiSize instead of the 16px emoji rule', async () => {
    const style = document.createElement('style');

    style.textContent = `
      .emojione { width: 16px; height: 16px; }
      .emoji-stock-picker .emoji-mart-emoji img.emojione {
        width: var(--emoji-stock-size, 22px);
        height: var(--emoji-stock-size, 22px);
      }
    `;
    document.head.appendChild(style);
    renderShell({ emojiSize: 32 });

    const img = (await screen.findByRole('button', { name: 'Family' })).querySelector('img');

    expect(img.style.width).toBe('32px');
    expect(img.style.height).toBe('32px');
    expect(window.getComputedStyle(img).width).toBe('32px');
    expect(window.getComputedStyle(img).height).toBe('32px');
    style.remove();
  });
});
