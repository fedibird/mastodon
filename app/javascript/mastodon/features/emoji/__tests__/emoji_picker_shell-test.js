/* eslint-disable react/prop-types */

import React from 'react';
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { useEmoji } from 'mastodon/actions/emojis';
import EmojiPickerShell from '../emoji_picker_shell';
import { notifySavedPersonalEmojiSet } from '../emoji_stock_source';
import StockEmojiPicker from '../stock_emoji_picker';

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

// Mimic Nimble's internal (uncontrolled) search state. A restored input value
// must also dispatch a search event to update the results, not just the DOM.
class StandardSearchProbe extends React.PureComponent {

  state = { query: '' };

  componentDidMount() {
    if (this.props.autoFocus && this.search) {
      this.search.focus();
    }
  }

  setSearchRef = node => {
    this.search = node;
  };

  handleSearch = event => {
    this.setState({ query: event.target.value });
  };

  render() {
    return (
      <div data-testid='standard-search-picker'>
        <div className='emoji-mart-search'>
          <input type='search' aria-label='Standard search' ref={this.setSearchRef} onChange={this.handleSearch} />
        </div>
        <output data-testid='standard-query'>{this.state.query || '(all)'}</output>
        <div className='emoji-mart-scroll' />
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

  it('hides action controls in both modes without blocking normal selection', async () => {
    const standardActions = [];
    const StandardTestPicker = props => {
      standardActions.push(props.actionsEnabled);
      return <StandardProbe {...props} />;
    };
    const loadStandardEmojiPicker = jest.fn(() => Promise.resolve({
      Picker: StandardTestPicker,
      Emoji: () => null,
    }));
    const { onPick } = renderShell({
      actionsEnabled: false,
      initialMode: 'personal',
      loadStandardEmojiPicker,
    });

    expect(await screen.findByRole('button', { name: 'Family' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Family' }));
    expect(onPick).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));
    expect(await screen.findByRole('button', { name: 'Standard pineapple' })).toBeInTheDocument();
    expect(standardActions).toContain(false);
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Standard pineapple' }));
    expect(onPick).toHaveBeenCalledTimes(2);
  });

  it('scrolls a category within the personal picker without scrolling its ancestors', async () => {
    renderShell();
    await screen.findByRole('button', { name: 'Family' });

    const scroll = document.querySelector('.emoji-stock-picker .emoji-mart-scroll');
    const category = scroll.querySelector('[data-category-id="cat-a"]');
    const scrollIntoView = jest.fn();

    Object.defineProperty(category, 'offsetTop', { value: 726, configurable: true });
    category.scrollIntoView = scrollIntoView;
    scroll.scrollTop = 120;

    fireEvent.click(screen.getByRole('button', { name: 'Apple' }));

    expect(scroll.scrollTop).toBe(726);
    expect(scrollIntoView).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Thumb' })).toHaveAttribute('aria-current', 'true');
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

  it('shares search text from a zero-result personal search to standard and back', async () => {
    const loadStandardEmojiPicker = jest.fn(() => Promise.resolve({ Picker: StandardSearchProbe, Emoji: () => null }));
    renderShell({ loadStandardEmojiPicker });

    const personal = await screen.findByRole('searchbox');

    fireEvent.change(personal, { target: { value: 'pineapple' } });
    expect(screen.getByText('No matching emojis found')).toBeInTheDocument();
    expect(loadStandardEmojiPicker).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));
    const standard = await screen.findByRole('searchbox', { name: 'Standard search' });

    expect(standard).toHaveValue('pineapple');
    expect(screen.getByTestId('standard-query')).toHaveTextContent('pineapple');

    fireEvent.change(standard, { target: { value: 'thumb' } });
    expect(screen.getByTestId('standard-query')).toHaveTextContent('thumb');
    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));

    expect(screen.getByRole('searchbox')).toHaveValue('thumb');
    expect(screen.getByRole('button', { name: 'Thumb light' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Thumb' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Family' })).not.toBeInTheDocument();
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
  });

  it('shares an empty query after clearing either mode', async () => {
    const loadStandardEmojiPicker = jest.fn(() => Promise.resolve({ Picker: StandardSearchProbe, Emoji: () => null }));
    renderShell({ initialMode: 'standard', loadStandardEmojiPicker });

    const standard = await screen.findByRole('searchbox', { name: 'Standard search' });

    fireEvent.change(standard, { target: { value: 'family' } });
    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));
    expect(screen.getByRole('searchbox')).toHaveValue('family');

    fireEvent.click(screen.getByRole('button', { name: 'Clear' }));
    expect(screen.getByRole('searchbox')).toHaveValue('');
    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));

    const clearedStandard = await screen.findByRole('searchbox', { name: 'Standard search' });

    expect(clearedStandard).toHaveValue('');
    expect(screen.getByTestId('standard-query')).toHaveTextContent('(all)');

    fireEvent.change(clearedStandard, { target: { value: 'fedibird' } });
    fireEvent.change(clearedStandard, { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));

    expect(screen.getByRole('searchbox')).toHaveValue('');
    expect(screen.getByRole('button', { name: 'Family' })).toBeInTheDocument();
  });

  it('uses the latest personal query if standard finishes loading after mode switches', async () => {
    const pending = deferred();
    const loadStandardEmojiPicker = jest.fn(() => pending.promise);
    renderShell({ loadStandardEmojiPicker });
    const personal = await screen.findByRole('searchbox');

    fireEvent.change(personal, { target: { value: 'pineapple' } });
    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));
    expect(await screen.findByText('Loading standard emoji')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));
    expect(screen.getByRole('searchbox')).toHaveValue('pineapple');

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'thumb' } });
    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));

    await act(async () => {
      pending.resolve({ Picker: StandardSearchProbe, Emoji: () => null });
    });

    expect(screen.getByRole('searchbox', { name: 'Standard search' })).toHaveValue('thumb');
    expect(screen.getByTestId('standard-query')).toHaveTextContent('thumb');
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
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

    const touch = { identifier: 1, clientX: 12, clientY: 20 };

    fireEvent.touchStart(skin, { touches: [touch] });
    fireEvent.touchEnd(skin, { changedTouches: [touch] });
    fireEvent.click(skin, { detail: 1 });
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

  it('moves vertically by the displayed rows around wide images and category boundaries', async () => {
    const stock = JSON.parse(JSON.stringify(fixture()));
    const items = stock.categories.reduce((all, category) => all.concat(category.items), []);

    stock.categories[0].items = items.slice(0, 4);
    stock.categories[1].items = items.slice(4);
    renderShell({ stockSource: ready(stock), perLine: 4 });
    await screen.findByRole('button', { name: 'Family' });

    const buttons = selected('[data-stock-key]');
    const rectangles = [
      { left: 0, top: 0, width: 34, height: 34 },
      { left: 34, top: 0, width: 34, height: 34 },
      { left: 68, top: 0, width: 34, height: 34 },
      { left: 0, top: 34, width: 112, height: 34 },
      { left: 0, top: 100, width: 34, height: 34 },
      { left: 34, top: 100, width: 34, height: 34 },
    ];

    buttons.forEach((button, index) => {
      button.getBoundingClientRect = () => rectangles[index];
    });

    buttons[1].focus();
    fireEvent.keyDown(document.activeElement, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(buttons[3]);
    fireEvent.keyDown(document.activeElement, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(buttons[1]);
    fireEvent.keyDown(document.activeElement, { key: 'ArrowDown' });
    fireEvent.keyDown(document.activeElement, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(buttons[5]);
    fireEvent.keyDown(document.activeElement, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(buttons[3]);

    buttons[0].focus();
    fireEvent.keyDown(document.activeElement, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(buttons[0]);
    buttons[4].focus();
    fireEvent.keyDown(document.activeElement, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(buttons[4]);
    fireEvent.keyDown(document.activeElement, { key: 'ArrowRight' });
    expect(document.activeElement).toBe(buttons[5]);

    // A later reflow changes the nearest column without remounting the picker.
    rectangles[4] = { left: 0, top: 100, width: 112, height: 34 };
    rectangles[5] = { left: 112, top: 100, width: 34, height: 34 };
    buttons[3].focus();
    fireEvent.keyDown(document.activeElement, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(buttons[4]);
  });

  it('uses only the filtered rows for vertical navigation, even with old button refs', async () => {
    renderShell();
    const search = await screen.findByRole('searchbox');
    const buttons = selected('[data-stock-key]');

    buttons.forEach((button, index) => {
      button.getBoundingClientRect = () => ({ left: 0, top: index * 40, width: 34, height: 34 });
    });
    fireEvent.change(search, { target: { value: 'family' } });
    expect(buttons[1].isConnected).toBe(false);

    const first = screen.getByRole('button', { name: 'Family' });
    const second = screen.getByRole('button', { name: 'Family again' });

    first.focus();
    fireEvent.keyDown(document.activeElement, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(second);
    fireEvent.keyDown(document.activeElement, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(first);
  });

  it('leaves horizontal arrows in the search field and repeats ArrowDown onto the same result', async () => {
    renderShell();

    const search = await screen.findByRole('searchbox');

    search.focus();
    fireEvent.change(search, { target: { value: 'thumb' } });
    search.setSelectionRange(2, 2);

    const left = new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true });
    const right = new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true });
    const up = new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true, cancelable: true });

    search.dispatchEvent(left);
    search.dispatchEvent(right);
    search.dispatchEvent(up);

    expect(left.defaultPrevented).toBe(false);
    expect(right.defaultPrevented).toBe(false);
    expect(up.defaultPrevented).toBe(false);
    expect(document.activeElement).toBe(search);
    expect(search.selectionStart).toBe(2);

    fireEvent.change(search, { target: { value: 'hash' } });
    search.focus();
    fireEvent.keyDown(search, { key: 'ArrowDown' });
    expect(document.activeElement).toHaveAttribute('data-stock-key', 'place-hash');

    search.focus();
    expect(document.activeElement).toBe(search);
    fireEvent.keyDown(search, { key: 'ArrowDown' });
    expect(document.activeElement).toHaveAttribute('data-stock-key', 'place-hash');
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

  it('keeps the saved heading through search and falls back to the name if its image fails', async () => {
    const stock = JSON.parse(JSON.stringify(fixture()));

    stock.categories[0].heading = { text: 'Z', image: stock.categories[0].items[0].image };
    renderShell({ stockSource: ready(stock) });

    const search = await screen.findByRole('searchbox');
    const anchor = screen.getByRole('button', { name: 'Zebra' });

    expect(anchor).toHaveAttribute('title', 'Zebra');
    expect(anchor.querySelector('img')).toHaveAttribute('src', 'https://assets.example/family.svg');
    fireEvent.change(search, { target: { value: 'Thumb light' } });
    expect(screen.queryByRole('button', { name: 'Family' })).not.toBeInTheDocument();
    expect(anchor.querySelector('img')).toHaveAttribute('src', 'https://assets.example/family.svg');
    fireEvent.error(anchor.querySelector('img'));
    expect(anchor).toHaveTextContent('Z');
    expect(anchor.querySelector('img')).toBeNull();
  });

  it('does not select after touch movement, scrolling, cancellation, or a second finger', async () => {
    const { onPick } = renderShell();
    const button = await screen.findByRole('button', { name: 'Family' });
    const touch = { identifier: 1, clientX: 20, clientY: 20 };
    const moved = { ...touch, clientY: 80 };

    fireEvent.touchStart(button, { touches: [touch] });
    fireEvent.touchMove(button, { touches: [moved] });
    fireEvent.touchEnd(button, { changedTouches: [moved] });
    fireEvent.click(button, { detail: 1 });
    expect(onPick).not.toHaveBeenCalled();

    fireEvent.touchStart(button, { touches: [touch] });
    document.querySelector('.emoji-stock-picker .emoji-mart-scroll').scrollTop = 30;
    fireEvent.touchEnd(button, { changedTouches: [touch] });
    fireEvent.click(button, { detail: 1 });
    expect(onPick).not.toHaveBeenCalled();

    fireEvent.touchStart(button, { touches: [touch] });
    fireEvent.touchCancel(button);
    fireEvent.touchEnd(button, { changedTouches: [touch] });
    fireEvent.click(button, { detail: 1 });
    expect(onPick).not.toHaveBeenCalled();

    fireEvent.touchStart(button, { touches: [touch, { ...touch, identifier: 2 }] });
    fireEvent.touchEnd(button, { changedTouches: [touch] });
    fireEvent.click(button, { detail: 1 });
    expect(onPick).not.toHaveBeenCalled();

    fireEvent.touchStart(button, { touches: [touch] });
    fireEvent.touchStart(document.body, { touches: [touch, { ...touch, identifier: 2 }] });
    fireEvent.touchEnd(document.body, { touches: [touch], changedTouches: [{ ...touch, identifier: 2 }] });
    fireEvent.touchEnd(button, { touches: [], changedTouches: [touch] });
    fireEvent.click(button, { detail: 1 });
    expect(onPick).not.toHaveBeenCalled();

    fireEvent.touchStart(button, { touches: [touch] });
    fireEvent.touchEnd(button, { changedTouches: [touch] });
    fireEvent.click(button, { detail: 1 });
    expect(onPick).toHaveBeenCalledTimes(1);
    // A keyboard/screen-reader click must not be mistaken for a ghost click.
    fireEvent.click(button, { detail: 0 });
    expect(onPick).toHaveBeenCalledTimes(2);
  });

  it('updates every mounted live personal picker immediately after a successful save', async () => {
    const onPick = jest.fn();
    const first = render(<EmojiPickerShell onPick={onPick} />);
    const second = render(<EmojiPickerShell onPick={onPick} />);

    await waitFor(() => expect(screen.getAllByText('No emoji in this set')).toHaveLength(2));
    act(() => notifySavedPersonalEmojiSet({ revision: 1, picker_emoji_size: 32, stock: fixture() }));
    expect(within(first.container).getByRole('button', { name: 'Family' })).toBeInTheDocument();
    expect(within(second.container).getByRole('button', { name: 'Family' })).toBeInTheDocument();
  });

  it('keeps the preview anchor highlight aligned with programmatic category movement', () => {
    const stock = JSON.parse(JSON.stringify(fixture()));
    const view = render(<StockEmojiPicker stock={stock} selectedCategoryId='cat-z' />);
    const first = screen.getByRole('button', { name: 'Zebra' });
    const second = screen.getByRole('button', { name: 'Apple' });

    fireEvent.click(second);
    expect(second).toHaveAttribute('aria-pressed', 'true');
    view.rerender(<StockEmojiPicker stock={{ categories: stock.categories.slice() }} selectedCategoryId='cat-z' />);
    expect(first).toHaveAttribute('aria-pressed', 'true');
    expect(second).toHaveAttribute('aria-pressed', 'false');
  });

  it.each([22, 32, 48])('keeps stock image heights at %ipx and preserves custom aspect ratios independently of body preferences', async emojiSize => {
    const style = document.createElement('style');
    const stock = JSON.parse(JSON.stringify(fixture()));

    Object.assign(stock.categories[1].items[1].image, { width: 120, height: 60 });

    style.textContent = `
      .emoji-mart-emoji { font-size: 0; }
      .emojione { font-size: inherit; width: 16px; height: 16px; }
      img.emojione:not(.reaction) {
        width: unset !important;
        max-width: min(100%, 10em);
      }
    `;
    document.head.appendChild(style);

    try {
      renderShell({ emojiSize, stockSource: ready(stock) });
      await screen.findByRole('button', { name: 'Family' });

      ['Family', 'Fedibird'].forEach(name => {
        const img = screen.getByRole('button', { name }).querySelector('img');

        // The body preference's 10em limit becomes zero in picker buttons.
        expect(img.matches('img.emojione:not(.reaction)')).toBe(false);
        const expectedWidth = name === 'Fedibird' ? emojiSize * 2 : emojiSize;

        expect(window.getComputedStyle(img).width).toBe(`${expectedWidth}px`);
        expect(window.getComputedStyle(img).height).toBe(`${emojiSize}px`);
        expect(img).toHaveAttribute('width', String(expectedWidth));
      });
    } finally {
      style.remove();
    }
  });

  it.each([
    {},
    { width: 320, height: 0 },
    { width: -1, height: 32 },
    { width: NaN, height: 32 },
    { width: 320, height: Infinity },
  ])('uses intrinsic custom image width when dimensions are missing or invalid: %j', async dimensions => {
    const stock = JSON.parse(JSON.stringify(fixture()));

    Object.assign(stock.categories[1].items[1].image, dimensions);
    renderShell({ emojiSize: 48, stockSource: ready(stock) });
    const img = (await screen.findByRole('button', { name: 'Fedibird' })).querySelector('img');

    expect(img.style.width).toBe('auto');
    expect(img.style.height).toBe('48px');
    expect(img).not.toHaveAttribute('width');
    expect(img).not.toHaveClass('emojione');
  });

  it('toggles edit mode with Edit/Done and resets when the shell reopens', async () => {
    const stock = ready(fixture());
    const loadStandardEmojiPicker = jest.fn(() => Promise.resolve({ Picker: () => null }));
    const { rerender, onPick, onRequestClose } = renderShell({
      stockSource: stock,
      loadStandardEmojiPicker,
    });
    await screen.findByRole('button', { name: 'Family' });

    expect(document.querySelector('.emoji-stock-picker__actions')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Edit' }));
    expect(screen.getByRole('button', { name: 'Done' })).toBeTruthy();
    expect(document.querySelector('.emoji-stock-picker__actions')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));
    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));
    expect(screen.getByRole('button', { name: 'Done' })).toBeTruthy();
    expect(document.querySelector('.emoji-stock-picker__actions')).toBeTruthy();

    rerender(
      <EmojiPickerShell
        open={false}
        onPick={onPick}
        onRequestClose={onRequestClose}
        stockSource={stock}
        loadStandardEmojiPicker={loadStandardEmojiPicker}
      />,
    );
    rerender(
      <EmojiPickerShell
        open
        onPick={onPick}
        onRequestClose={onRequestClose}
        stockSource={stock}
        loadStandardEmojiPicker={loadStandardEmojiPicker}
      />,
    );
    await screen.findByRole('button', { name: 'Family' });
    expect(screen.getByRole('button', { name: 'Edit' })).toBeTruthy();
    expect(document.querySelector('.emoji-stock-picker__actions')).toBeNull();
  });
});
