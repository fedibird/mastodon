import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import NimbleEmoji from 'emoji-mart/dist-es/components/emoji/nimble-emoji';
import NimblePicker from 'emoji-mart/dist-es/components/picker/nimble-picker';
import { getSanitizedData } from 'emoji-mart/dist/utils';
import nimblePickerData from './emoji_mart_nimble_data';
import { openEmojiActions } from './emoji_actions/bus';
import { referenceFromPickerEmoji } from './emoji_actions/reference';

const messages = defineMessages({
  manage: { id: 'emoji_actions.manage', defaultMessage: 'Emoji actions' },
  manageHint: { id: 'emoji_actions.manage_hint', defaultMessage: 'Select an emoji, then open actions' },
});

// The full standard dataset stays in this async chunk. Skin-tone previews
// and the empty-search emoji use the same bound data as the picker.

function openFromEmojiObject(emoji, anchor, event) {
  const reference = referenceFromPickerEmoji(emoji);

  if (!reference) {
    return false;
  }

  if (event) {
    event.preventDefault();
    event.stopPropagation();
  }

  return openEmojiActions(reference, {
    anchor: anchor || null,
    source: 'standard_picker',
  });
}

function customEmojiFromTitle(id, custom) {
  const list = Array.isArray(custom) ? custom : [];

  return list.find(entry => {
    if (!entry) {
      return false;
    }

    if (entry.id === id || entry.name === id) {
      return true;
    }

    const shortNames = entry.short_names || [];

    return shortNames.includes(id) || shortNames.some(name => `:${name}:` === id);
  }) || null;
}

// Resolve identity from the concrete mart button only. Never reuse hover state
// and never parse aria-label display names.
function emojiFromMartButton(button, skin, custom = []) {
  if (!button || button.closest('[data-emoji-actions="1"]')) {
    return null;
  }

  const id = button.getAttribute('title');

  if (!id) {
    return null;
  }

  const customEmoji = customEmojiFromTitle(id, custom);

  if (customEmoji) {
    const shortcode = (customEmoji.short_names && customEmoji.short_names[0]) || customEmoji.id;

    return {
      ...customEmoji,
      custom: true,
      id: customEmoji.id || shortcode,
      colons: customEmoji.colons || `:${shortcode}:`,
    };
  }

  return getSanitizedData(id, skin, 'twitter', nimblePickerData) || null;
}

function referenceFromMartButton(button, skin, custom = []) {
  return referenceFromPickerEmoji(emojiFromMartButton(button, skin, custom));
}

class Picker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    skin: PropTypes.number,
    set: PropTypes.string,
    custom: PropTypes.array,
  };

  static defaultProps = {
    set: 'twitter',
    skin: 1,
    custom: [],
  };

  state = {
    // Manage-bar selection. Updated by hover, keyboard focus, and touch on a
    // cell — never authoritative for contextmenu / Shift+F10 on another cell.
    selectedEmoji: null,
  };

  componentDidMount() {
    this.attachPickerHooks();
  }

  componentDidUpdate() {
    this.attachPickerHooks();
  }

  componentWillUnmount() {
    this.detachRootListeners();
  }

  setPickerRef = picker => {
    this.picker = picker;
    this.attachPickerHooks();
  };

  currentSkin = () => {
    return (this.picker && (this.picker.state.skin || this.picker.props.skin)) || this.props.skin || 1;
  };

  currentCustom = () => {
    return (this.picker && this.picker.props.custom) || this.props.custom || [];
  };

  selectEmoji = emoji => {
    if (!emoji || !referenceFromPickerEmoji(emoji)) {
      return;
    }

    this.setState({ selectedEmoji: emoji });
  };

  selectEmojiFromButton = button => {
    const emoji = emojiFromMartButton(button, this.currentSkin(), this.currentCustom());

    if (emoji) {
      this.selectEmoji(emoji);
    }

    return emoji;
  };

  attachPickerHooks = () => {
    const picker = this.picker;

    if (!picker || picker.__emojiActionsPatched) {
      this.bindRootListeners();
      return;
    }

    const originalOver = picker.handleEmojiOver && picker.handleEmojiOver.bind(picker);

    picker.handleEmojiOver = emoji => {
      this.selectEmoji(emoji);

      if (originalOver) {
        originalOver(emoji);
      }
    };

    picker.__emojiActionsPatched = true;
    this.bindRootListeners();
  };

  bindRootListeners = () => {
    const picker = this.picker;
    const root = picker && picker.scroll && picker.scroll.parentNode;

    if (!root || this.root === root) {
      return;
    }

    this.detachRootListeners();
    this.root = root;
    this.scroll = picker.scroll;

    let frame = null;

    const cancelRefresh = () => {
      if (frame !== null) {
        cancelAnimationFrame(frame);
        frame = null;
      }
    };

    const refresh = () => {
      frame = null;

      if (picker.scroll) {
        picker.updateCategoriesSize();
        picker.handleScroll();
      }
    };

    const scheduleRefresh = () => {
      if (frame === null) {
        frame = requestAnimationFrame(refresh);
      }
    };

    const handleImage = event => {
      if (event.target.matches('.emoji-mart-emoji-custom > img')) {
        scheduleRefresh();
      }
    };

    const handleAnchor = event => {
      if (event.target.closest('.emoji-mart-anchor')) {
        cancelRefresh();
        refresh();
      }
    };

    const emojiButtonFromEvent = event => {
      const origin = event.target && event.target.nodeType === Node.ELEMENT_NODE
        ? event.target
        : event.target && event.target.parentElement;

      return origin && origin.closest ? origin.closest('button.emoji-mart-emoji') : null;
    };

    // Context / keyboard menu must target the event cell only. Outside a cell
    // (search, anchors, empty chrome) is a no-op — never reuse selectedEmoji.
    const openActionsForEventButton = (event, button) => {
      if (!button) {
        return false;
      }

      const emoji = emojiFromMartButton(button, this.currentSkin(), this.currentCustom());
      const reference = referenceFromPickerEmoji(emoji);

      if (!reference) {
        return false;
      }

      this.selectEmoji(emoji);
      event.preventDefault();
      event.stopPropagation();
      openEmojiActions(reference, { anchor: button, source: 'standard_picker' });
      return true;
    };

    const handleContextMenu = event => {
      openActionsForEventButton(event, emojiButtonFromEvent(event));
    };

    const handleKeyDown = event => {
      const isMenuKey = event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey);

      if (!isMenuKey) {
        return;
      }

      openActionsForEventButton(event, emojiButtonFromEvent(event));
    };

    const handleFocusIn = event => {
      const button = emojiButtonFromEvent(event);

      if (button) {
        this.selectEmojiFromButton(button);
      }
    };

    // Touch / pointer without hover: arm the manage bar from the cell without
    // changing insert-on-click / long-press preview behavior.
    const handlePointerDown = event => {
      const button = emojiButtonFromEvent(event);

      if (button) {
        this.selectEmojiFromButton(button);
      }
    };

    this._cleanup = () => {
      if (this.resizeObserver) {
        this.resizeObserver.disconnect();
      } else {
        window.removeEventListener('resize', scheduleRefresh);
      }

      cancelRefresh();
      this.scroll.removeEventListener('load', handleImage, true);
      this.scroll.removeEventListener('error', handleImage, true);
      this.root.removeEventListener('click', handleAnchor, true);
      this.root.removeEventListener('contextmenu', handleContextMenu);
      this.root.removeEventListener('keydown', handleKeyDown);
      this.root.removeEventListener('focusin', handleFocusIn);
      this.root.removeEventListener('pointerdown', handlePointerDown);
      this.root = null;
      this.scroll = null;
      this._cleanup = null;
    };

    this.scroll.addEventListener('load', handleImage, true);
    this.scroll.addEventListener('error', handleImage, true);
    this.root.addEventListener('click', handleAnchor, true);
    this.root.addEventListener('contextmenu', handleContextMenu);
    this.root.addEventListener('keydown', handleKeyDown);
    this.root.addEventListener('focusin', handleFocusIn);
    this.root.addEventListener('pointerdown', handlePointerDown);

    this.resizeObserver = window.ResizeObserver ? new window.ResizeObserver(scheduleRefresh) : null;

    if (this.resizeObserver) {
      this.resizeObserver.observe(this.root);
    } else {
      window.addEventListener('resize', scheduleRefresh);
    }
  };

  detachRootListeners = () => {
    if (this._cleanup) {
      this._cleanup();
    }
  };

  handleManage = event => {
    const { selectedEmoji } = this.state;

    if (!selectedEmoji) {
      return;
    }

    openFromEmojiObject(selectedEmoji, event.currentTarget, event);
  };

  render() {
    const { intl, ...props } = this.props;
    const { selectedEmoji } = this.state;
    const canManage = Boolean(referenceFromPickerEmoji(selectedEmoji));

    return (
      <div className='emoji-standard-picker-with-actions'>
        <NimblePicker
          {...props}
          ref={this.setPickerRef}
          data={nimblePickerData}
          emojiTooltip
        />
        <div className='emoji-picker-actions-bar'>
          <button
            type='button'
            className='emoji-actions-trigger'
            data-emoji-actions-bar='1'
            disabled={!canManage}
            aria-label={intl.formatMessage(messages.manage)}
            title={intl.formatMessage(canManage ? messages.manage : messages.manageHint)}
            onClick={this.handleManage}
          >
            ⋯
          </button>
        </div>
      </div>
    );
  }

}

const IntlPicker = injectIntl(Picker);

function Emoji(props) {
  return (
    <NimbleEmoji {...props} data={nimblePickerData} />
  );
}

export {
  IntlPicker as Picker,
  Emoji,
  referenceFromMartButton,
  emojiFromMartButton,
  openFromEmojiObject,
};
