import React from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import { Picker } from '../emoji_picker';
import EmojiPickerShell from '../emoji_picker_shell';
import {
  installEmojiMutesForTests,
  resetEmojiMuteStoreForTests,
  setEmojiMuteViewerSignedInForTests,
} from '../emoji_mute_store';

jest.mock('emoji-mart/dist-es/components/emoji/nimble-emoji', () => () => null);
jest.mock('emoji-mart/dist-es/components/picker/nimble-picker', () => {
  const ReactInside = require('react');

  return class NimbleProbe extends ReactInside.Component {

    render() {
      const { data, custom, recent } = this.props;
      const categories = data && data.categories || [];

      return ReactInside.createElement('div', { 'data-testid': 'nimble-probe' },
        categories.map(category => ReactInside.createElement('div', { key: category.id || category.name },
          (category.emojis || []).map(id => {
            const emoji = data.emojis[id];

            return ReactInside.createElement('button', {
              type: 'button',
              key: `${category.id}-${id}`,
              'aria-label': id,
            }, emoji && emoji.native);
          }),
        )),
        (custom || []).map(emoji => ReactInside.createElement('img', {
          key: emoji.custom_emoji_id || emoji.id,
          alt: (emoji.short_names && emoji.short_names[0]) || emoji.id,
          src: emoji.imageUrl,
        })),
        (recent || []).map(id => ReactInside.createElement('span', {
          key: `recent-${id}`,
          'aria-label': `recent-${id}`,
        }, id)),
      );
    }

  };
});

jest.mock('mastodon/api', () => () => ({
  get: jest.fn(() => new Promise(() => {})),
}));

const SKIN = '👍\u{1F3FB}';

const item = (key, native, label) => ({
  key,
  label,
  image: { src: `https://assets.example/${key}.svg`, alt: native, title: label },
  search: [label, native],
  selection: { id: key, custom: false, native },
  reference: { kind: 'unicode', native },
});

const stock = () => ({
  categories: [
    {
      id: 'tones',
      name: 'Tones',
      heading: {
        text: 'T',
        image: { src: 'https://assets.example/light.svg', alt: SKIN },
        reference: { kind: 'unicode', native: SKIN },
      },
      items: [
        item('light', SKIN, 'Light'),
        item('plain', '👍', 'Plain'),
        item('family', '👩\u200d👩\u200d👦\u200d👦', 'Family'),
      ],
    },
    {
      id: 'again',
      name: 'Again',
      items: [item('light-again', SKIN, 'Light again')],
    },
  ],
});

const loadReadyStock = () => Promise.resolve({ status: 'ready', stock: stock() });
const hangStandardPicker = () => new Promise(() => {});
const ignorePick = () => {};

const renderShell = () => render(
  <IntlProvider locale='en'>
    <EmojiPickerShell
      stockSource={loadReadyStock}
      loadStandardEmojiPicker={hangStandardPicker}
      onPick={ignorePick}
    />
  </IntlProvider>,
);

describe('picker DOM excludes hide_in_picker candidates', () => {
  beforeEach(() => {
    resetEmojiMuteStoreForTests();
    setEmojiMuteViewerSignedInForTests(true);
  });

  afterEach(() => {
    resetEmojiMuteStoreForTests();
  });

  it('keeps personal candidates out of the DOM until a confirmed document allows them', async () => {
    renderShell();

    expect(await screen.findByText('Emoji choices stay hidden until mute rules are confirmed.')).toBeTruthy();
    expect(document.querySelector('img')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Light' })).toBeNull();

    act(() => {
      installEmojiMutesForTests({
        revision: '3',
        emoji_mutes: [
          {
            emoji: { kind: 'unicode', native: SKIN },
            effects: { hide_in_picker: true, replace_in_text: false, hide_reactions: true, reject_reactions_to_own_posts: true },
          },
          {
            emoji: { kind: 'unicode', native: '👩\u200d👩\u200d👦\u200d👦' },
            effects: { hide_in_picker: false, replace_in_text: true, hide_reactions: true, reject_reactions_to_own_posts: true },
          },
        ],
      });
    });

    const images = Array.from(document.querySelectorAll('img')).map(image => image.getAttribute('src'));

    expect(images).toEqual(['https://assets.example/plain.svg', 'https://assets.example/family.svg']);
    expect(document.body.textContent).not.toContain(SKIN);
    expect(screen.getByRole('button', { name: 'Plain' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Family' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Light' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Light again' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Tones' }).textContent).toBe('Tones');
    expect(screen.getByRole('button', { name: 'Tones' }).querySelector('img')).toBeNull();

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'Light' } });

    expect(document.querySelector('img')).toBeNull();
    expect(screen.getByText('No matching emojis found')).toBeTruthy();

    act(() => {
      installEmojiMutesForTests({ revision: '4', emoji_mutes: [] });
    });

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: '' } });

    expect(Array.from(document.querySelectorAll('.emoji-mart-category-list img')).map(image => image.getAttribute('src'))).toEqual([
      'https://assets.example/light.svg',
      'https://assets.example/plain.svg',
      'https://assets.example/family.svg',
      'https://assets.example/light-again.svg',
    ]);
    expect(screen.getByRole('button', { name: 'Tones' }).querySelector('img')).toHaveAttribute('src', 'https://assets.example/light.svg');
  });

  it('does not keep a qualified representative that shares a file with an earlier native', async () => {
    const shared = 'https://assets.example/203c.svg';
    const plain = '‼';
    const qualified = '‼️';
    const mark = (key, native) => ({
      key,
      label: native,
      image: { src: shared, alt: native, title: native },
      search: [native],
      selection: { id: key, custom: false, native },
      reference: { kind: 'unicode', native },
    });
    const marks = (items, heading) => ({
      categories: [{
        id: 'marks',
        name: 'Marks',
        heading,
        items,
      }],
    });
    const savedHeading = {
      text: 'M',
      image: { src: shared, alt: qualified },
      reference: { kind: 'unicode', native: qualified },
    };
    const forward = marks([mark('plain', plain), mark('qualified', qualified)], savedHeading);
    const reversed = marks([mark('qualified', qualified), mark('plain', plain)], savedHeading);
    const unbound = marks([mark('plain', plain)], { text: 'M', image: { src: shared, alt: qualified } });
    const loadForward = () => Promise.resolve({ status: 'ready', stock: forward });
    const loadReversed = () => Promise.resolve({ status: 'ready', stock: reversed });
    const loadUnbound = () => Promise.resolve({ status: 'ready', stock: unbound });
    const shell = stockSource => (
      <IntlProvider locale='en'>
        <EmojiPickerShell
          stockSource={stockSource}
          loadStandardEmojiPicker={hangStandardPicker}
          onPick={ignorePick}
        />
      </IntlProvider>
    );

    const view = render(shell(loadForward));

    expect(await screen.findByText('Emoji choices stay hidden until mute rules are confirmed.')).toBeTruthy();

    act(() => {
      installEmojiMutesForTests({
        revision: '1',
        emoji_mutes: [{ emoji: { kind: 'unicode', native: qualified }, effects: { hide_in_picker: true, hide_reactions: false } }],
      });
    });

    const anchor = await screen.findByRole('button', { name: 'Marks' });

    expect(anchor.querySelector('img')).toBeNull();
    expect(anchor).toHaveTextContent('Marks');
    expect(document.querySelector(`[alt="${qualified}"]`)).toBeNull();
    expect(document.querySelector(`[title="${qualified}"]`)).toBeNull();
    expect(document.querySelector(`[aria-label="${qualified}"]`)).toBeNull();
    expect(screen.getByRole('button', { name: plain })).toBeTruthy();
    expect(screen.queryByRole('button', { name: qualified })).toBeNull();

    view.rerender(shell(loadReversed));

    expect((await screen.findByRole('button', { name: 'Marks' })).querySelector('img')).toBeNull();
    expect(document.querySelector(`[alt="${qualified}"]`)).toBeNull();
    expect(document.querySelector(`[title="${qualified}"]`)).toBeNull();
    expect(await screen.findByRole('button', { name: plain })).toBeTruthy();
    expect(screen.queryByRole('button', { name: qualified })).toBeNull();

    view.rerender(shell(loadUnbound));

    expect((await screen.findByRole('button', { name: 'Marks' })).querySelector('img')).toBeNull();
    expect(document.querySelector(`[alt="${qualified}"]`)).toBeNull();
    expect(document.querySelector(`[title="${qualified}"]`)).toBeNull();

    act(() => {
      installEmojiMutesForTests({ revision: '2', emoji_mutes: [] });
    });
    view.rerender(shell(loadForward));

    expect((await screen.findByRole('button', { name: 'Marks' })).querySelector('img')).toHaveAttribute('src', shared);
    expect(screen.getByRole('button', { name: 'Marks' }).querySelector('img')).toHaveAttribute('alt', '');
    expect(screen.getByRole('button', { name: qualified })).toBeTruthy();
    expect(screen.getByRole('button', { name: plain })).toBeTruthy();
  });

  it('does not leave a keyboard cursor on a candidate that disappeared', async () => {
    renderShell();
    act(() => {
      installEmojiMutesForTests({ revision: '1', emoji_mutes: [] });
    });

    const light = await screen.findByRole('button', { name: 'Light' });

    fireEvent.focus(light);
    expect(light.getAttribute('aria-current')).toBe('true');

    act(() => {
      installEmojiMutesForTests({
        revision: '2',
        emoji_mutes: [{ emoji: { kind: 'unicode', native: SKIN }, effects: { hide_in_picker: true } }],
      });
    });

    expect(screen.queryByRole('button', { name: 'Light' })).toBeNull();
    expect(document.querySelector('[aria-current="true"]')).toBeNull();
  });

  it('omits muted unicode, custom, and recent candidates from the standard picker', () => {
    installEmojiMutesForTests({
      revision: '9',
      emoji_mutes: [
        { emoji: { kind: 'unicode', native: '👍' }, effects: { hide_in_picker: true } },
        { emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, effects: { hide_in_picker: true } },
      ],
    });

    render(
      <IntlProvider locale='en'>
        <Picker
          custom={[
            { id: 'blob', short_names: ['blob'], custom: true, custom_emoji_id: '11', imageUrl: '/muted.png' },
            { id: 'blob', short_names: ['blob'], custom: true, custom_emoji_id: '22', imageUrl: '/kept.png' },
          ]}
          recent={['+1', 'grinning', 'blob']}
          skin={1}
        />
      </IntlProvider>,
    );

    expect(screen.queryByRole('button', { name: '+1' })).toBeNull();
    expect(screen.getByRole('button', { name: 'grinning' })).toBeTruthy();
    expect(document.querySelector('img[src="/muted.png"]')).toBeNull();
    expect(document.querySelector('img[alt="blob"][src="/kept.png"]')).toBeTruthy();
    expect(screen.queryByLabelText('recent-+1')).toBeNull();
    expect(screen.getByLabelText('recent-grinning')).toBeTruthy();
    expect(screen.getByLabelText('recent-blob')).toBeTruthy();
  });
});
