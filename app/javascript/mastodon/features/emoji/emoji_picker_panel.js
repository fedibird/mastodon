import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { supportsPassiveEvents } from 'detect-passive-events';
import { assetHost } from 'mastodon/utils/config';
import { autoPlayEmoji, disableAutoFocusToEmojiSearch, emojiPickerDisablePersonal } from 'mastodon/initial_state';
import EmojiPickerShell from './emoji_picker_shell';
import { emojiPickerInitialMode } from './emoji_picker_preferences';
import { getPickerEmojiSize, loadPersonalEmojiStock, subscribePickerEmojiSize } from './emoji_stock_source';
import { emojiPickerTheme } from './emoji_picker_theme';

const messages = defineMessages({
  emoji_search: { id: 'emoji_button.search', defaultMessage: 'Search...' },
  emoji_not_found: { id: 'emoji_button.not_found', defaultMessage: 'No matching emojis found' },
  emoji_not_found_reaction: { id: 'emoji_button.reaction_not_found', defaultMessage: 'No emojos!! (╯°□°）╯︵ ┻━┻' },
  custom: { id: 'emoji_button.custom', defaultMessage: 'Custom' },
  recent: { id: 'emoji_button.recent', defaultMessage: 'Frequently used' },
  search_results: { id: 'emoji_button.search_results', defaultMessage: 'Search results' },
  people: { id: 'emoji_button.people', defaultMessage: 'People' },
  nature: { id: 'emoji_button.nature', defaultMessage: 'Nature' },
  food: { id: 'emoji_button.food', defaultMessage: 'Food & Drink' },
  activity: { id: 'emoji_button.activity', defaultMessage: 'Activity' },
  travel: { id: 'emoji_button.travel', defaultMessage: 'Travel & Places' },
  objects: { id: 'emoji_button.objects', defaultMessage: 'Objects' },
  symbols: { id: 'emoji_button.symbols', defaultMessage: 'Symbols' },
  flags: { id: 'emoji_button.flags', defaultMessage: 'Flags' },
});

const listenerOptions = supportsPassiveEvents ? { passive: false } : false;
const backgroundImageFn = () => `${assetHost}/emoji/sheet_15.png`;

// Emoji actions render in a portal outside the picker DOM. Clicks / touchends
// on that menu must not count as "outside" or the picker closes before the
// menu item action runs (observed on desktop Chrome).
export function isEmojiActionsMenuTarget(target) {
  let node = target;

  // Some engines report the text node inside the <a> as event.target.
  if (node && node.nodeType === Node.TEXT_NODE) {
    node = node.parentElement;
  }

  return Boolean(
    node
    && typeof node.closest === 'function'
    && node.closest('[data-emoji-actions-menu="1"]'),
  );
}

const BASE_CATEGORIES = [
  'recent',
  'people',
  'nature',
  'foods',
  'activity',
  'places',
  'objects',
  'symbols',
  'flags',
];

// Copy the Nimble object before filling an empty native. Personal Unicode
// already has a finished native, including skin tone and ZWJ, and is not
// passed through the standard skin setting again.
export function normalizeEmojiPayload(emoji) {
  const payload = emoji && typeof emoji === 'object' ? { ...emoji } : {};

  if (!payload.native && payload.colons) {
    payload.native = payload.colons;
  }

  return payload;
}

class ModifierPickerMenu extends React.PureComponent {

  static propTypes = {
    active: PropTypes.bool,
    onSelect: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    Emoji: PropTypes.func,
  };

  handleClick = event => {
    this.props.onSelect(event.currentTarget.getAttribute('data-index') * 1);
  };

  UNSAFE_componentWillReceiveProps(nextProps) {
    if (nextProps.active) {
      this.attachListeners();
    } else {
      this.removeListeners();
    }
  }

  componentWillUnmount() {
    this.removeListeners();
  }

  handleDocumentClick = event => {
    if (this.node && !this.node.contains(event.target)) {
      this.props.onClose();
    }
  };

  attachListeners() {
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  removeListeners() {
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  setRef = node => {
    this.node = node;
  };

  renderSkin = skin => {
    const { Emoji } = this.props;

    if (!Emoji) {
      return null;
    }

    return (
      <Emoji
        sheetColumns={62}
        sheetRows={62}
        emoji='fist'
        set='twitter'
        size={22}
        sheetSize={32}
        skin={skin}
        backgroundImageFn={backgroundImageFn}
      />
    );
  };

  render() {
    const { active } = this.props;

    return (
      <div className='emoji-picker-dropdown__modifiers__menu' style={{ display: active ? 'block' : 'none' }} ref={this.setRef}>
        {[1, 2, 3, 4, 5, 6].map(skin => (
          <button key={skin} type='button' onClick={this.handleClick} data-index={skin}>
            {this.renderSkin(skin)}
          </button>
        ))}
      </div>
    );
  }

}

class ModifierPicker extends React.PureComponent {

  static propTypes = {
    active: PropTypes.bool,
    modifier: PropTypes.number,
    onChange: PropTypes.func,
    onClose: PropTypes.func,
    onOpen: PropTypes.func,
    Emoji: PropTypes.func,
  };

  handleClick = () => {
    if (this.props.active) {
      this.props.onClose();
    } else {
      this.props.onOpen();
    }
  };

  handleSelect = modifier => {
    this.props.onChange(modifier);
    this.props.onClose();
  };

  render() {
    const { active, modifier, Emoji } = this.props;

    if (!Emoji) {
      return null;
    }

    return (
      <div className='emoji-picker-dropdown__modifiers'>
        <Emoji
          sheetColumns={62}
          sheetRows={62}
          emoji='fist'
          set='twitter'
          size={22}
          sheetSize={32}
          skin={modifier}
          onClick={this.handleClick}
          backgroundImageFn={backgroundImageFn}
        />
        <ModifierPickerMenu active={active} onSelect={this.handleSelect} onClose={this.props.onClose} Emoji={Emoji} />
      </div>
    );
  }

}

class EmojiPickerPanel extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    pickersEmoji: ImmutablePropTypes.map,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
    skinTone: PropTypes.number,
    onSkinTone: PropTypes.func,
    onPick: PropTypes.func.isRequired,
    onRequestClose: PropTypes.func.isRequired,
    onStandardActive: PropTypes.func,
    autoFocus: PropTypes.bool,
    initialMode: PropTypes.oneOf(['standard', 'personal']),
    notFoundVariant: PropTypes.oneOf(['plain', 'reaction']),
  };

  static defaultProps = {
    skinTone: 1,
    onSkinTone: () => {},
    frequentlyUsedEmojis: [],
    autoFocus: !disableAutoFocusToEmojiSearch,
    notFoundVariant: 'plain',
  };

  state = {
    modifierOpen: false,
    mode: emojiPickerDisablePersonal ? 'standard' : (this.props.initialMode || emojiPickerInitialMode()),
    Emoji: null,
    catalogHold: false,
    emojiSize: getPickerEmojiSize(),
  };

  componentDidMount() {
    this.mounted = true;
    // When personal sets are disabled, do not attach their storage listener or
    // fetch stock just to determine a size already supplied in initial state.
    this.unsubscribeSize = () => {};
    if (!emojiPickerDisablePersonal) {
      this.unsubscribeSize = subscribePickerEmojiSize(emojiSize => this.setState({ emojiSize }));
      // Refresh the shared size on every opening, including standard mode after
      // a save on another device. Personal mode shares this bounded stock read.
      loadPersonalEmojiStock().catch(() => {});
    }
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  componentWillUnmount() {
    this.mounted = false;
    this.unsubscribeSize();
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  setRef = node => {
    this.node = node;
  };

  handleDocumentClick = event => {
    if (this.node && this.node.contains(event.target)) {
      return;
    }

    if (isEmojiActionsMenuTarget(event.target)) {
      return;
    }

    event.stopPropagation();
    event.preventDefault();
    this.props.onRequestClose(event);
  };

  handleMode = mode => {
    this.setState({ mode, modifierOpen: mode === 'standard' ? this.state.modifierOpen : false });

    if (mode === 'standard') {
      this.holdForCatalog();
    }
  };

  // The first standard paint waits for a catalog request that is still in
  // flight, so Nimble's constructor sees the fetched custom list. A later
  // change still remounts, and the shell keeps the search text and focus.
  holdForCatalog() {
    const start = this.props.onStandardActive;

    if (!start) {
      return null;
    }

    const request = start();

    if (!request || typeof request.then !== 'function') {
      return null;
    }

    const generation = (this.catalogGeneration || 0) + 1;

    this.catalogGeneration = generation;
    this.setState({ catalogHold: true });

    const finish = () => {
      if (!this.mounted || generation !== this.catalogGeneration) {
        return;
      }

      this.setState({ catalogHold: false });
    };

    return Promise.resolve(request).then(finish, finish);
  }

  handleStandardModule = loaded => {
    if (!this.mounted || !loaded) {
      return;
    }

    this.emojiComponent = loaded.Emoji;
    this.setState({ Emoji: loaded.Emoji });
  };

  handlePick = (emoji, event) => {
    this.props.onPick(normalizeEmojiPayload(emoji), event);
  };

  handleModifierOpen = () => {
    this.setState({ modifierOpen: true });
  };

  handleModifierClose = () => {
    this.setState({ modifierOpen: false });
  };

  handleModifierChange = modifier => {
    this.props.onSkinTone(modifier);
  };

  customRevision(custom) {
    if (!custom || typeof custom.length !== 'number' || custom.length === 0) {
      return 'empty';
    }

    return custom.map(emoji => {
      if (!emoji) {
        return '';
      }

      return emoji.id || (emoji.short_names && emoji.short_names[0]) || '';
    }).join('\n');
  }

  categories() {
    const { pickersEmoji } = this.props;
    const categories = pickersEmoji && pickersEmoji.get ? pickersEmoji.get('categories') : null;
    const sorted = BASE_CATEGORIES.slice();

    if (categories && typeof categories[Symbol.iterator] === 'function') {
      sorted.splice(1, 0, ...Array.from(categories).sort());
    }

    return sorted;
  }

  notFound = () => {
    const { intl, notFoundVariant } = this.props;
    const Emoji = this.state.Emoji;
    const label = notFoundVariant === 'reaction' ? messages.emoji_not_found_reaction : messages.emoji_not_found;

    return (
      <div className='emoji-mart-no-results'>
        {Emoji && (
          <Emoji
            emoji='sleuth_or_spy'
            set='twitter'
            size={32}
            sheetSize={32}
            sheetColumns={62}
            sheetRows={62}
            backgroundImageFn={backgroundImageFn}
          />
        )}
        <div className='emoji-mart-no-results-label'>
          {intl.formatMessage(label)}
        </div>
      </div>
    );
  };

  render() {
    const { intl, pickersEmoji, frequentlyUsedEmojis, skinTone, autoFocus, initialMode } = this.props;
    const { modifierOpen, mode, Emoji, emojiSize } = this.state;
    const perLine = Math.floor(34 * 8 / (emojiSize + 12));
    const custom = pickersEmoji && pickersEmoji.get ? (pickersEmoji.get('custom_emojis') || []) : [];
    const recent = frequentlyUsedEmojis && frequentlyUsedEmojis.length > 0 ? frequentlyUsedEmojis : undefined;

    return (
      <div className={classNames('emoji-picker-dropdown__menu', { selecting: modifierOpen })} ref={this.setRef}>
        <EmojiPickerShell
          open
          personalEnabled={!emojiPickerDisablePersonal}
          initialMode={initialMode || emojiPickerInitialMode()}
          autoFocus={autoFocus}
          emojiSize={emojiSize}
          animate={autoPlayEmoji}
          theme={emojiPickerTheme()}
          perLine={perLine}
          onPick={this.handlePick}
          onRequestClose={this.props.onRequestClose}
          onModeChange={this.handleMode}
          onStandardModule={this.handleStandardModule}
          deferStandardPicker={this.state.catalogHold}
          standardAccessory={mode === 'standard' ? (
            <ModifierPicker
              Emoji={Emoji}
              active={modifierOpen}
              modifier={skinTone}
              onOpen={this.handleModifierOpen}
              onClose={this.handleModifierClose}
              onChange={this.handleModifierChange}
            />
          ) : null}
          standardPickerProps={{
            pickerRevision: this.customRevision(custom),
            custom,
            i18n: {
              search: intl.formatMessage(messages.emoji_search),
              categories: {
                search: intl.formatMessage(messages.search_results),
                recent: intl.formatMessage(messages.recent),
                people: intl.formatMessage(messages.people),
                nature: intl.formatMessage(messages.nature),
                foods: intl.formatMessage(messages.food),
                activity: intl.formatMessage(messages.activity),
                places: intl.formatMessage(messages.travel),
                objects: intl.formatMessage(messages.objects),
                symbols: intl.formatMessage(messages.symbols),
                flags: intl.formatMessage(messages.flags),
                custom: intl.formatMessage(messages.custom),
              },
            },
            include: this.categories(),
            recent,
            skin: skinTone,
            showPreview: false,
            showSkinTones: false,
            notFound: this.notFound,
            emojiTooltip: true,
          }}
        />
      </div>
    );
  }

}

export default injectIntl(EmojiPickerPanel);
