import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import IconButton from './icon_button';
import Overlay from 'react-overlays/Overlay';
import classNames from 'classnames';
import { supportsPassiveEvents } from 'detect-passive-events';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { EmojiPicker as EmojiPickerAsync } from '../features/ui/util/async-components';
import { assetHost } from 'mastodon/utils/config';
import { pickerEmojiSize, disableAutoFocusToEmojiSearch } from 'mastodon/initial_state';

const messages = defineMessages({
  emoji: { id: 'emoji_button.label', defaultMessage: 'Insert emoji' },
  emoji_search: { id: 'emoji_button.search', defaultMessage: 'Search...' },
  emoji_not_found: { id: 'emoji_button.not_found', defaultMessage: 'No emojos!! (╯°□°）╯︵ ┻━┻' },
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

let EmojiPicker, Emoji; // load asynchronously

const listenerOptions = supportsPassiveEvents ? { passive: true } : false;
let id = 0;

const backgroundImageFn = () => `${assetHost}/emoji/sheet_15.png`;

const notFoundFn = () => (
  <div className='emoji-mart-no-results'>
    <Emoji
      emoji='sleuth_or_spy'
      set='twitter'
      size={32}
      sheetSize={32}
      sheetColumns={62}
      sheetRows={62}
      backgroundImageFn={backgroundImageFn}
    />

    <div className='emoji-mart-no-results-label'>
      <FormattedMessage id='emoji_mart_button.not_found' defaultMessage='No matching emojis found' />
    </div>
  </div>
);

class ModifierPickerMenu extends React.PureComponent {

  static propTypes = {
    active: PropTypes.bool,
    onSelect: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
  };

  handleClick = e => {
    this.props.onSelect(e.currentTarget.getAttribute('data-index') * 1);
  }

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

  handleDocumentClick = e => {
    if (this.node && !this.node.contains(e.target)) {
      this.props.onClose();
    }
  }

  attachListeners() {
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  removeListeners() {
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  setRef = c => {
    this.node = c;
  }

  render() {
    const { active } = this.props;

    return (
      <div className='emoji-picker-dropdown__modifiers__menu' style={{ display: active ? 'block' : 'none' }} ref={this.setRef}>
        <button onClick={this.handleClick} data-index={1}><Emoji sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={1} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={2}><Emoji sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={2} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={3}><Emoji sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={3} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={4}><Emoji sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={4} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={5}><Emoji sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={5} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={6}><Emoji sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={6} backgroundImageFn={backgroundImageFn} /></button>
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
  };

  handleClick = () => {
    if (this.props.active) {
      this.props.onClose();
    } else {
      this.props.onOpen();
    }
  }

  handleSelect = modifier => {
    this.props.onChange(modifier);
    this.props.onClose();
  }

  render() {
    const { active, modifier } = this.props;

    return (
      <div className='emoji-picker-dropdown__modifiers'>
        <Emoji sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={modifier} onClick={this.handleClick} backgroundImageFn={backgroundImageFn} />
        <ModifierPickerMenu active={active} onSelect={this.handleSelect} onClose={this.props.onClose} />
      </div>
    );
  }

}

@injectIntl
class ReactionPicker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    pickersEmoji: ImmutablePropTypes.map,
    onPickEmoji: PropTypes.func.isRequired,
    onSkinTone: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    skinTone: PropTypes.number.isRequired,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
    loading: PropTypes.bool,
    style: PropTypes.object,
  };

  static defaultProps = {
    style: {},
    loading: true,
    frequentlyUsedEmojis: [],
  };

  state = {
    modifierOpen: false,
    placement: null,
  };

  handleDocumentClick = e => {
    if (this.node && !this.node.contains(e.target)) {
      this.props.onClose();
    }
  }

  componentDidMount() {
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  componentWillUnmount() {
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  setRef = c => {
    this.node = c;
  }

  getI18n = () => {
    const { intl } = this.props;

    return {
      search: intl.formatMessage(messages.emoji_search),
      notfound: intl.formatMessage(messages.emoji_not_found),
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
    };
  }

  handleClick = (emoji, event) => {
    if (!emoji.native) {
      emoji.native = emoji.colons;
    }
    if (!(event.ctrlKey || event.metaKey)) {
      this.props.onClose();
    }
    this.props.onPickEmoji(emoji);
  }

  handleModifierOpen = () => {
    this.setState({ modifierOpen: true });
  }

  handleModifierClose = () => {
    this.setState({ modifierOpen: false });
  }

  handleModifierChange = modifier => {
    this.props.onSkinTone(modifier);
  }

  render() {
    const { loading, style, intl, pickersEmoji, skinTone, frequentlyUsedEmojis } = this.props;

    if (loading) {
      return <div style={{ height: 349, width: 299 }} />;
    }

    const title = intl.formatMessage(messages.emoji);

    const { modifierOpen } = this.state;

    const categoriesSort = [
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

    categoriesSort.splice(1, 0, ...Array.from(pickersEmoji.get('categories')).sort());
    const emojiSize = Number(pickerEmojiSize) || 22;

    return (
      <div className={classNames('emoji-picker-dropdown__menu', { selecting: modifierOpen })} style={style} ref={this.setRef}>
        <EmojiPicker
          sheetColumns={62}
          sheetRows={62}
          perLine={Math.floor(34 * 8 / (emojiSize + 12))}
          emojiSize={emojiSize}
          sheetSize={32}
          custom={pickersEmoji.get('custom_emojis')}
          color=''
          emoji=''
          set='twitter'
          title={title}
          i18n={this.getI18n()}
          onClick={this.handleClick}
          include={categoriesSort}
          recent={frequentlyUsedEmojis}
          skin={skinTone}
          showPreview={false}
          showSkinTones={false}
          backgroundImageFn={backgroundImageFn}
          notFound={notFoundFn}
          autoFocus={!disableAutoFocusToEmojiSearch}
          emojiTooltip
        />

        <ModifierPicker
          active={modifierOpen}
          modifier={skinTone}
          onOpen={this.handleModifierOpen}
          onClose={this.handleModifierClose}
          onChange={this.handleModifierChange}
        />
      </div>
    );
  }

}

class ReactionPickerDropdownMenu extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    style: PropTypes.object,
    placement: PropTypes.string,
    arrowOffsetLeft: PropTypes.string,
    arrowOffsetTop: PropTypes.string,
    pickersEmoji: ImmutablePropTypes.map,
    onPickEmoji: PropTypes.func.isRequired,
    onSkinTone: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    skinTone: PropTypes.number.isRequired,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
  };

  static defaultProps = {
    style: {},
    placement: 'bottom',
  };

  state = {
    loading: true,
  };

  handleDocumentClick = e => {
    if (this.node && !this.node.contains(e.target)) {
      this.props.onClose();
    }
  }

  componentDidMount () {
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, listenerOptions);
    this.setState({ loading: true });
    EmojiPickerAsync().then(EmojiMart => {
      EmojiPicker = EmojiMart.Picker;
      Emoji = EmojiMart.Emoji;
      this.setState({ loading: false });
    }).catch(() => {
      this.setState({ loading: false });
    });
  }

  componentWillUnmount () {
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  setRef = c => {
    this.node = c;
  }

  render() {
    const { onClose, style, placement } = this.props;
    const { pickersEmoji, onPickEmoji, onSkinTone, skinTone, frequentlyUsedEmojis } = this.props;
    const { loading } = this.state;

    return (
      <div className={`dropdown-menu dropdown-menu-reaction ${placement}`} style={style} ref={this.setRef}>
        <ReactionPicker
          pickersEmoji={pickersEmoji}
          loading={loading}
          onClose={onClose}
          onPickEmoji={onPickEmoji}
          onSkinTone={onSkinTone}
          skinTone={skinTone}
          frequentlyUsedEmojis={frequentlyUsedEmojis}
        />
      </div>
    );
  }

}

class ReactionPickerDropdown extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    icon: PropTypes.string.isRequired,
    size: PropTypes.number.isRequired,
    title: PropTypes.string.isRequired,
    active: PropTypes.bool,
    pressed: PropTypes.bool,
    iconButtonClass: PropTypes.string,
    disabled: PropTypes.bool,
    status: ImmutablePropTypes.map,
    isUserTouching: PropTypes.func,
    onOpen: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    openDropdownId: PropTypes.string,
    pickersEmoji: ImmutablePropTypes.map,
    onPickEmoji: PropTypes.func.isRequired,
    onSkinTone: PropTypes.func.isRequired,
    skinTone: PropTypes.number.isRequired,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
    counter: PropTypes.number,
  };

  static defaultProps = {
    active: false,
    pressed: false,
    iconButtonClass: 'status__action-bar-button',
  };

  state = {
    id: `reaction:${id++}`,
  };

  handleClick = ({ type }) => {
    if (this.state.id === this.props.openDropdownId) {
      this.handleClose();
    } else {
      this.props.onOpen(this.state.id, type !== 'click');
    }
  }

  handleClose = () => {
    if (this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
      this.activeElement = null;
    }
    this.props.onClose(this.state.id);
  }

  handleMouseDown = () => {
    this.activeElement = document.activeElement;
  }

  handleButtonKeyDown = (e) => {
    switch(e.key) {
    case ' ':
    case 'Enter':
      this.handleMouseDown();
      break;
    }
  }

  handleKeyPress = (e) => {
    switch(e.key) {
    case ' ':
    case 'Enter':
      this.handleClick(e);
      e.stopPropagation();
      e.preventDefault();
      break;
    }
  }

  setTargetRef = c => {
    this.target = c;
  }

  findTarget = () => {
    return this.target;
  }

  componentWillUnmount = () => {
    if (this.state.id === this.props.openDropdownId) {
      this.handleClose();
    }
  }

  render() {
    const { icon, size, title, disabled, openDropdownId, active, pressed, iconButtonClass, counter } = this.props;
    const { pickersEmoji, onPickEmoji, onSkinTone, skinTone, frequentlyUsedEmojis } = this.props;
    const open = this.state.id === openDropdownId;

    return (
      <div className='emoji-picker-dropdown'>
        <span ref={this.setTargetRef}>
          <IconButton
            icon={icon}
            title={title}
            active={active}
            pressed={pressed}
            className={iconButtonClass}
            disabled={disabled}
            size={size}
            onClick={this.handleClick}
            onMouseDown={this.handleMouseDown}
            onKeyDown={this.handleButtonKeyDown}
            onKeyPress={this.handleKeyPress}
            counter={counter}
          />
        </span>

        <Overlay show={open} offset={[5, 5]} placement={'bottom'} flip target={this.findTarget} popperConfig={{ strategy: 'fixed' }}>
          {({ props, arrowProps, placement }) => (
            <div {...props}>
              <div className={`dropdown-animation ${placement}`}>
                <div className={`dropdown-menu__arrow ${placement}`} {...arrowProps} />
                <ReactionPickerDropdownMenu
                  onClose={this.handleClose}
                  pickersEmoji={pickersEmoji}
                  onPickEmoji={onPickEmoji}
                  onSkinTone={onSkinTone}
                  skinTone={skinTone}
                  frequentlyUsedEmojis={frequentlyUsedEmojis}
                />
              </div>
            </div>
          )}
        </Overlay>
      </div>
    );
  }

}

export default ReactionPickerDropdown;

