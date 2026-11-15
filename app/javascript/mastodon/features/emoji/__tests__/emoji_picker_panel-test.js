import React from 'react';
import PropTypes from 'prop-types';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import NimblePicker from 'emoji-mart/dist/components/picker/nimble-picker';
import { Map as ImmutableMap } from 'immutable';
import { EmojiPicker } from 'mastodon/features/ui/util/async-components';
import { resetStandardEmojiPickerLoaderForTests } from '../standard_emoji_loader';
import EmojiPickerPanel from '../emoji_picker_panel';
import { preloadStandardEmojiPickerIfNeeded } from '../emoji_picker_preferences';
import { consumeEmojiPickerEscape, resetEmojiPickerEscapeForTests } from '../emoji_picker_escape';
import * as stockSource from '../emoji_stock_source';

jest.mock('mastodon/features/ui/util/async-components', () => ({
  EmojiPicker: jest.fn(),
}));

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: descriptor => descriptor.defaultMessage,
  };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

const pickerData = ImmutableMap({
  categories: new Set(['custom-fedibird']),
  custom_emojis: [{ id: 'fedibird', custom: true }],
});

const mockNimbleEmoji = { id: 'smile', native: '', colons: ':smile:', custom: false };

class StandardPickerStub extends React.Component {

  static propTypes = {
    onClick: PropTypes.func,
  };

  handleClick = event => {
    this.props.onClick(mockNimbleEmoji, event);
  };

  render() {
    return <button type='button' onClick={this.handleClick}>Standard smile</button>;
  }

}

const resolvePicker = () => {
  EmojiPicker.mockImplementation(() => Promise.resolve({
    Picker: StandardPickerStub,
    Emoji: function StandardEmojiStub() {
      return null;
    },
  }));
};

describe('EmojiPickerPanel', () => {
  beforeEach(() => {
    resetStandardEmojiPickerLoaderForTests();
    resetEmojiPickerEscapeForTests();
    EmojiPicker.mockReset();
    resolvePicker();
  });

  it('revalidates the shared size on standard-only openings without a local tab change', async () => {
    const load = jest.spyOn(stockSource, 'loadPersonalEmojiStock').mockResolvedValue({ status: 'ready', stock: { categories: [] } });
    const props = { initialMode: 'standard', onPick: jest.fn(), onRequestClose: jest.fn() };

    try {
      const first = render(<EmojiPickerPanel {...props} />);

      await screen.findByRole('button', { name: 'Standard smile' });
      expect(load).toHaveBeenCalledTimes(1);
      first.unmount();
      const second = render(<EmojiPickerPanel {...props} />);

      await screen.findByRole('button', { name: 'Standard smile' });
      expect(load).toHaveBeenCalledTimes(2);
      second.unmount();
    } finally {
      load.mockRestore();
    }
  });

  it('does not load the standard picker from an empty personal set or a zero-result search', async () => {
    const onStandardActive = jest.fn();

    render(
      <EmojiPickerPanel
        initialMode='personal'
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
        onStandardActive={onStandardActive}
      />,
    );

    expect(await screen.findByRole('button', { name: 'Standard' })).toBeInTheDocument();
    expect(EmojiPicker).not.toHaveBeenCalled();
    expect(onStandardActive).not.toHaveBeenCalled();
    expect(screen.getByText(/No emoji in this set/i)).toBeInTheDocument();

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'zzzz-no-such-emoji' } });

    expect(screen.getByText(/No matching emoji/i)).toBeInTheDocument();
    expect(EmojiPicker).not.toHaveBeenCalled();
    expect(onStandardActive).not.toHaveBeenCalled();
  });

  it.each([
    ['personal', false, 'personal'],
    ['standard', false, 'standard'],
    ['personal', true, 'personal'],
    ['standard', true, 'standard'],
  ])('opens %s when prefer is %s and lazy is %s without falling back', async (mode) => {
    const onStandardActive = jest.fn();

    render(
      <EmojiPickerPanel
        initialMode={mode}
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
        onStandardActive={onStandardActive}
      />,
    );

    if (mode === 'personal') {
      expect(await screen.findByRole('searchbox')).toBeInTheDocument();
      expect(EmojiPicker).not.toHaveBeenCalled();
      expect(onStandardActive).not.toHaveBeenCalled();
      return;
    }

    await waitFor(() => expect(EmojiPicker).toHaveBeenCalledTimes(1));
    expect(onStandardActive).toHaveBeenCalledTimes(1);
    expect(await screen.findByRole('button', { name: 'Standard smile' })).toBeInTheDocument();
  });

  it('anchors the skin-tone selector to the standard picker below the mode bar', async () => {
    const onSkinTone = jest.fn();

    class ModifierEmojiStub extends React.PureComponent {

      static propTypes = {
        onClick: PropTypes.func,
      };

      render() {
        return this.props.onClick ? <button type='button' aria-label='Skin tone' onClick={this.props.onClick} /> : null;
      }

    }

    EmojiPicker.mockImplementation(() => Promise.resolve({
      Picker: StandardPickerStub,
      Emoji: ModifierEmojiStub,
    }));

    const { container } = render(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
        onSkinTone={onSkinTone}
      />,
    );

    const smile = await screen.findByRole('button', { name: 'Standard smile' });
    const standard = smile.closest('.emoji-picker-shell__standard');

    expect(standard).not.toBeNull();
    expect(standard.querySelector('.emoji-picker-dropdown__modifiers')).not.toBeNull();
    expect(container.querySelector('.emoji-picker-dropdown__menu > .emoji-picker-dropdown__modifiers')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Skin tone' }));
    const option = standard.querySelector('.emoji-picker-dropdown__modifiers__menu button[data-index="3"]');

    expect(option).not.toBeNull();
    fireEvent.click(option);
    expect(onSkinTone).toHaveBeenCalledWith(3);

    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));
    expect(container.querySelector('.emoji-picker-dropdown__modifiers')).toBeNull();
  });

  it('loads the standard picker only after an explicit switch and keeps a copied native fallback', async () => {
    const seen = [];
    const onPick = jest.fn(emoji => {
      seen.push(emoji);
    });

    render(
      <EmojiPickerPanel
        initialMode='personal'
        pickersEmoji={pickerData}
        onPick={onPick}
        onRequestClose={jest.fn()}
        onStandardActive={jest.fn()}
      />,
    );

    fireEvent.click(await screen.findByRole('button', { name: 'Standard' }));

    const smile = await screen.findByRole('button', { name: 'Standard smile' });
    fireEvent.click(smile);
    expect(EmojiPicker).toHaveBeenCalledTimes(1);
    expect(seen[0].native).toBe(':smile:');
    expect(seen[0]).not.toBe(mockNimbleEmoji);
    expect(mockNimbleEmoji.native).toBe('');
  });

  it('marks escape so a window keyup does not close the modal behind the picker', async () => {
    const onRequestClose = jest.fn();
    const modalClose = jest.fn();

    render(
      <EmojiPickerPanel
        initialMode='personal'
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={onRequestClose}
      />,
    );

    const search = await screen.findByRole('searchbox');

    search.focus();
    fireEvent.keyDown(search, { key: 'Escape' });
    const keyUp = new KeyboardEvent('keyup', { key: 'Escape', bubbles: true });

    if (!consumeEmojiPickerEscape(keyUp)) {
      modalClose();
    }

    expect(onRequestClose).toHaveBeenCalledTimes(1);
    expect(modalClose).not.toHaveBeenCalled();
  });

  it('rebuilds the standard picker when custom emoji arrive after it mounts', async () => {
    class ConstructorPicker extends React.Component {

      static propTypes = {
        custom: PropTypes.array,
      };

      constructor(props) {
        super(props);
        this.state = { custom: props.custom || [], query: '', ready: false };
      }

      componentDidMount() {
        // Nimble's first paint is the first categories only. The rest mount
        // on a later timer, and a search hides only the nodes that exist then.
        this.timer = setTimeout(() => {
          this.setState({ ready: true });
        }, 60);
      }

      componentWillUnmount() {
        clearTimeout(this.timer);
      }

      handleChange = () => {
        const value = this.input ? this.input.value : '';

        this.setState({ query: value });

        if (!this.scroll) {
          return;
        }

        const sections = this.scroll.querySelectorAll('.emoji-mart-category');

        for (let i = 0; i < sections.length; i += 1) {
          const label = sections[i].querySelector('.emoji-mart-category-label');
          const name = label && label.getAttribute('data-name');

          if (name && name !== 'Search') {
            sections[i].style.display = value ? 'none' : '';
          }
        }
      };

      setInput = node => {
        this.input = node;
      };

      setScroll = node => {
        this.scroll = node;
      };

      render() {
        const query = this.state.query || '';
        const categories = [
          { name: 'Search', text: 'results' },
          { name: 'People', text: 'smile' },
        ];

        if (this.state.ready) {
          categories.push({ name: 'Nature', text: 'dog' });
        }

        return (
          <div>
            <div className='emoji-mart-search'>
              <input
                ref={this.setInput}
                type='search'
                aria-label='Standard search'
                onChange={this.handleChange}
              />
              <button type='button' aria-label='Clear' disabled={query === ''}>Clear</button>
            </div>
            <div className='emoji-mart-search-results' hidden={query === ''}>
              {query === '' ? '0' : '20'} results
            </div>
            <div className='emoji-mart-scroll' ref={this.setScroll}>
              {categories.map(category => (
                <section key={category.name} className='emoji-mart-category'>
                  <div className='emoji-mart-category-label' data-name={category.name}>{category.name}</div>
                  <span>{category.text}</span>
                </section>
              ))}
            </div>
            {this.state.custom.map(emoji => (
              <button key={emoji.id} type='button' className='emoji-mart-emoji-custom'>{emoji.id}</button>
            ))}
          </div>
        );
      }

    }

    EmojiPicker.mockImplementation(() => Promise.resolve({
      Picker: ConstructorPicker,
      Emoji: function StandardEmojiStub() {
        return null;
      },
    }));

    const view = render(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={ImmutableMap({ categories: new Set(), custom_emojis: [] })}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
      />,
    );

    const search = await screen.findByRole('searchbox', { name: 'Standard search' });

    search.focus();
    fireEvent.change(search, { target: { value: 'smile' } });
    expect(screen.getByRole('button', { name: 'Clear' })).toBeEnabled();
    expect(screen.getByText('20 results')).not.toHaveAttribute('hidden');
    expect(screen.getByText('smile').closest('.emoji-mart-category').style.display).toBe('none');
    expect(view.container.querySelector('.emoji-mart-emoji-custom')).toBeNull();

    view.rerender(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={ImmutableMap({
          categories: new Set(['custom']),
          custom_emojis: [{ id: 'fedibird', short_names: ['fedibird'], custom: true }],
        })}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
      />,
    );

    const restored = await screen.findByRole('searchbox', { name: 'Standard search' });

    expect(restored.value).toBe('smile');
    expect(document.activeElement).toBe(restored);
    expect(screen.getByRole('button', { name: 'Clear' })).toBeEnabled();
    expect(screen.getByText('20 results')).not.toHaveAttribute('hidden');
    expect(screen.getByText('smile').closest('.emoji-mart-category').style.display).toBe('none');
    expect(screen.getByRole('button', { name: 'fedibird' })).toHaveClass('emoji-mart-emoji-custom');

    await waitFor(() => {
      expect(screen.getByText('dog').closest('.emoji-mart-category').style.display).toBe('none');
    });
    expect(screen.getByText('results').closest('.emoji-mart-category').style.display).not.toBe('none');
    expect(screen.getByText('20 results')).not.toHaveAttribute('hidden');
  });

  it('keeps later Nimble categories hidden after a restored search', async () => {
    const emoji = (id, search) => ({
      name: id,
      unified: '1F600',
      short_names: [id],
      emoticons: [],
      keywords: [search],
      search,
    });
    const data = {
      categories: [
        { id: 'people', name: 'People', emojis: ['smile'] },
        { id: 'nature', name: 'Nature', emojis: ['dog'] },
        { id: 'foods', name: 'Foods', emojis: ['apple'] },
        { id: 'activity', name: 'Activity', emojis: ['soccer'] },
      ],
      emojis: {
        smile: emoji('smile', 'smile'),
        dog: emoji('dog', 'dog'),
        apple: emoji('apple', 'apple'),
        soccer: emoji('soccer', 'soccer'),
      },
      aliases: {},
    };

    function RealNimble(props) {
      return <NimblePicker {...props} data={data} />;
    }

    EmojiPicker.mockImplementation(() => Promise.resolve({
      Picker: RealNimble,
      Emoji: function StandardEmojiStub() {
        return null;
      },
    }));

    const view = render(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={ImmutableMap({ categories: new Set(), custom_emojis: [] })}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
      />,
    );
    const search = await screen.findByRole('searchbox', { name: 'Search...' });

    await new Promise(resolve => setTimeout(resolve, 150));
    search.focus();
    fireEvent.change(search, { target: { value: 'smile' } });
    await waitFor(() => {
      expect(document.querySelector('.emoji-mart-category[aria-label="Nature"]').style.display).toBe('none');
    });

    view.rerender(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={ImmutableMap({
          categories: new Set(['custom']),
          custom_emojis: [{ id: 'fedibird', name: 'fedibird', short_names: ['fedibird'], custom: true }],
        })}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
      />,
    );

    const restored = await screen.findByRole('searchbox', { name: 'Search...' });

    expect(restored.value).toBe('smile');
    await new Promise(resolve => setTimeout(resolve, 150));
    expect(restored.value).toBe('smile');
    expect(document.activeElement).toBe(restored);
    expect(screen.getByRole('button', { name: 'Clear' })).toBeEnabled();
    const searchCategory = document.querySelector('.emoji-mart-category[aria-label="Search results"]');
    const nature = document.querySelector('.emoji-mart-category[aria-label="Nature"]');

    expect(nature.style.display).toBe('none');
    expect(document.querySelector('.emoji-mart-category[aria-label="People"]').style.display).toBe('none');
    expect(searchCategory.style.display).not.toBe('none');
    expect(searchCategory.querySelector('[aria-label="smile"], [title="smile"]')).not.toBeNull();
    expect(nature.querySelector('[aria-label="dog"], [title="dog"]')).not.toBeNull();
  });

  it('preloads the standard module when the default non-lazy setting applies', async () => {
    await preloadStandardEmojiPickerIfNeeded(true);
    expect(EmojiPicker).not.toHaveBeenCalled();

    // The default for emoji_picker_lazy_load_standard is now false. Passing
    // undefined uses that default, so the standard module is preloaded.
    await preloadStandardEmojiPickerIfNeeded(undefined);
    expect(EmojiPicker).toHaveBeenCalledTimes(1);

    await preloadStandardEmojiPickerIfNeeded(false);
    expect(EmojiPicker).toHaveBeenCalledTimes(1);
  });

  it('does not close when a click lands on the emoji actions portal menu', async () => {
    const onRequestClose = jest.fn();

    render(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={onRequestClose}
      />,
    );

    await screen.findByRole('button', { name: 'Standard smile' });

    const portal = document.createElement('div');
    portal.setAttribute('data-emoji-actions-menu', '1');
    const item = document.createElement('a');
    item.setAttribute('role', 'button');
    item.textContent = 'Mute emoji';
    portal.appendChild(item);
    document.body.appendChild(portal);

    fireEvent.click(item);
    fireEvent.touchEnd(item);

    expect(onRequestClose).not.toHaveBeenCalled();

    // Text-node targets inside the menu must also count as inside.
    const text = item.firstChild;
    expect(text && text.nodeType).toBe(Node.TEXT_NODE);
    fireEvent.click(item, { target: text });
    expect(onRequestClose).not.toHaveBeenCalled();

    fireEvent.click(document.body);
    expect(onRequestClose).toHaveBeenCalled();

    document.body.removeChild(portal);
  });
});
