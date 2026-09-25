import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { EmojiPicker as EmojiPickerAsync } from '../../ui/util/async-components';
import IconButton from '../../../components/icon_button';
import emojiCompressed from 'mastodon/features/emoji/emoji_compressed';
import Overlay from 'react-overlays/Overlay';
import classNames from 'classnames';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { supportsPassiveEvents } from 'detect-passive-events';
import { assetHost } from 'mastodon/utils/config';
import { pickerEmojiSize, disableAutoFocusToEmojiSearch } from 'mastodon/initial_state';

const nimblePickerData = emojiCompressed[5];

const messages = defineMessages({
  emoji: { id: 'emoji_button.label', defaultMessage: 'Insert emoji' },
  emoji_search: { id: 'emoji_button.search', defaultMessage: 'Search...' },
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
      data={nimblePickerData}
      emoji='sleuth_or_spy'
      set='twitter'
      size={32}
      sheetSize={32}
      sheetColumns={62}
      sheetRows={62}
      backgroundImageFn={backgroundImageFn}
    />

    <div className='emoji-mart-no-results-label'>
      <FormattedMessage id='emoji_button.not_found' defaultMessage='No matching emojis found' />
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
        <button onClick={this.handleClick} data-index={1}><Emoji data={nimblePickerData} sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={1} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={2}><Emoji data={nimblePickerData} sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={2} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={3}><Emoji data={nimblePickerData} sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={3} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={4}><Emoji data={nimblePickerData} sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={4} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={5}><Emoji data={nimblePickerData} sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={5} backgroundImageFn={backgroundImageFn} /></button>
        <button onClick={this.handleClick} data-index={6}><Emoji data={nimblePickerData} sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={6} backgroundImageFn={backgroundImageFn} /></button>
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
        <Emoji data={nimblePickerData} sheetColumns={62} sheetRows={62} emoji='fist' set='twitter' size={22} sheetSize={32} skin={modifier} onClick={this.handleClick} backgroundImageFn={backgroundImageFn} />
        <ModifierPickerMenu active={active} onSelect={this.handleSelect} onClose={this.props.onClose} />
      </div>
    );
  }

}

@injectIntl
class EmojiPickerMenu extends React.PureComponent {

  static propTypes = {
    pickersEmoji: ImmutablePropTypes.map,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
    loading: PropTypes.bool,
    onClose: PropTypes.func.isRequired,
    onPick: PropTypes.func.isRequired,
    style: PropTypes.object,
    intl: PropTypes.object.isRequired,
    skinTone: PropTypes.number.isRequired,
    onSkinTone: PropTypes.func.isRequired,
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
      this.props.onClose(e);
    }
  }

  componentDidMount() {
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, { passive: false });
  }

  componentWillUnmount() {
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('touchend', this.handleDocumentClick, { passive: false });
  }

  setRef = c => {
    this.node = c;
  }

  getI18n = () => {
    const { intl } = this.props;

    return {
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
    };
  }

  handleClick = (emoji, event) => {
    if (!emoji.native) {
      emoji.native = emoji.colons;
    }
    if (!(event.ctrlKey || event.metaKey)) {
      this.props.onClose(event);
    }
    this.props.onPick(emoji);
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
      return <div style={{ width: 299 }} />;
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
          data={nimblePickerData}
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

class EmojiPickerDropdown extends React.PureComponent {

  static propTypes = {
    pickersEmoji: ImmutablePropTypes.map,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
    intl: PropTypes.object.isRequired,
    onOpen: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    openDropdownId: PropTypes.string,
    onPickEmoji: PropTypes.func.isRequired,
    onSkinTone: PropTypes.func.isRequired,
    skinTone: PropTypes.number.isRequired,
    button: PropTypes.node,
  };

  state = {
    loading: false,
    placement: 'bottom',
    id: `custom_emoji:${id++}`,
  };

  onShowDropdown = ({ target, type }) => {
    if (!EmojiPicker) {
      this.setState({ loading: true });

      EmojiPickerAsync().then(EmojiMart => {
        EmojiPicker = EmojiMart.Picker;
        Emoji = EmojiMart.Emoji;

        this.setState({ loading: false });
      }).catch(() => {
        this.setState({ loading: false });
      });
    }

    const { top } = target.getBoundingClientRect();
    this.setState({ placement: top * 2 < innerHeight ? 'bottom' : 'top' });
    this.props.onOpen(this.state.id, type !== 'click');
  }

  onHideDropdown = (e) => {
    e.stopPropagation();
    e.preventDefault();
    this.props.onClose(this.state.id);
}

  handleClick = (e) => {
    if (!this.state.loading && (!e.key || e.key === 'Enter')) {
      if (this.state.id === this.props.openDropdownId) {
        this.onHideDropdown(e);
      } else {
        this.onShowDropdown(e);
      }
    }
  }

  handleMouseDown = () => {
    this.activeElement = document.activeElement;
  }

  handleCustomButtonClick = (e) => {
    const { button } = this.props;

    if (button.props.onClick) {
      button.props.onClick(e);
    }

    if (!e.defaultPrevented) {
      this.handleClick(e);
    }
  }

  handleCustomButtonMouseDown = (e) => {
    this.handleMouseDown();

    const { button } = this.props;

    if (button.props.onMouseDown) {
      button.props.onMouseDown(e);
    }
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
      break;
    case 'Escape':
      this.onHideDropdown(e);
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
      this.onHideDropdown();
    }
  }

  render() {
    const { intl, onPickEmoji, onSkinTone, skinTone, frequentlyUsedEmojis, button, pickersEmoji, openDropdownId } = this.props;
    const title = intl.formatMessage(messages.emoji);
    const { loading, placement } = this.state;
    const open = this.state.id === openDropdownId;
    const nativeButton = React.isValidElement(button) && button.type === 'button';

    return (
      <div className='emoji-picker-dropdown'>
        {nativeButton ? (
          <div className='emoji-button'>
            {React.cloneElement(button, {
              ref: this.setTargetRef,
              title: button.props.title || title,
              'aria-label': button.props['aria-label'] || title,
              'aria-expanded': open,
              onClick: this.handleCustomButtonClick,
              onMouseDown: this.handleCustomButtonMouseDown,
            })}
          </div>
        ) : (
          <div ref={this.setTargetRef}
            className='emoji-button'
            title={title}
            aria-label={title}
            aria-expanded={open}
            role='button'
            onClick={button ? this.handleClick : null}
            tabIndex={0}
          >
            {button || <IconButton
              className='privacy-dropdown__value-icon'
              icon='smile-o'
              title={intl.formatMessage(messages.emoji)}
              expanded={open}
              inverted
              style={{ height: null, lineHeight: '27px' }}
              onClick={this.handleClick}
              onMouseDown={this.handleMouseDown}
              onKeyDown={this.handleButtonKeyDown}
              onKeyPress={this.handleKeyPress}
            />}
          </div>
        )}

        <Overlay show={open && !loading} offset={[5, 15]} placement={placement} target={this.findTarget} popperConfig={{ strategy: 'fixed' }}>
          {({ props, arrowProps, placement }) => (
            <div {...props}>
              <div className={`dropdown-animation ${placement}`}>
                <div className={`dropdown-menu__arrow ${placement}`} {...arrowProps} />
                <EmojiPickerMenu
                  pickersEmoji={pickersEmoji}
                  loading={loading}
                  onClose={this.onHideDropdown}
                  onPick={onPickEmoji}
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

export default injectIntl(EmojiPickerDropdown);
