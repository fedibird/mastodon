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

function referenceFromMartButton(button, skin) {
  if (!button || button.closest('[data-emoji-actions="1"]')) {
    return null;
  }

  // title is the catalog id when emojiTooltip is enabled. Never parse aria-label
  // names — those are display strings and are wrong for custom rows.
  const id = button.getAttribute('title');

  if (!id) {
    return null;
  }

  const emoji = getSanitizedData(id, skin, 'twitter', nimblePickerData);

  return referenceFromPickerEmoji(emoji);
}

class Picker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    skin: PropTypes.number,
    set: PropTypes.string,
  };

  static defaultProps = {
    set: 'twitter',
    skin: 1,
  };

  state = {
    focusedEmoji: null,
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

  attachPickerHooks = () => {
    const picker = this.picker;

    if (!picker || picker.__emojiActionsPatched) {
      this.bindRootListeners();
      return;
    }

    const originalOver = picker.handleEmojiOver && picker.handleEmojiOver.bind(picker);

    picker.handleEmojiOver = emoji => {
      this.setState({ focusedEmoji: emoji });

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

    const skin = () => (this.picker && (this.picker.state.skin || this.picker.props.skin)) || this.props.skin || 1;

    const referenceForButton = button => {
      // Prefer the live Nimble selection object (native/skin/ZWJ/custom fields).
      // title→getSanitizedData is a unicode fallback only — never aria-label.
      const focused = this.state.focusedEmoji;
      const fromFocus = referenceFromPickerEmoji(focused);

      if (fromFocus) {
        return fromFocus;
      }

      return referenceFromMartButton(button, skin());
    };

    const handleContextMenu = event => {
      const button = event.target && event.target.closest && event.target.closest('button.emoji-mart-emoji');

      if (!button) {
        return;
      }

      const reference = referenceForButton(button);

      if (!reference) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();
      openEmojiActions(reference, { anchor: button, source: 'standard_picker' });
    };

    const handleKeyDown = event => {
      const isMenuKey = event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey);

      if (!isMenuKey) {
        return;
      }

      const origin = event.target && event.target.nodeType === Node.ELEMENT_NODE
        ? event.target
        : event.target && event.target.parentElement;
      const button = origin && origin.closest && origin.closest('button.emoji-mart-emoji');
      const reference = referenceForButton(button);

      if (!reference) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();
      openEmojiActions(reference, { anchor: button, source: 'standard_picker' });
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
      this.root = null;
      this.scroll = null;
      this._cleanup = null;
    };

    this.scroll.addEventListener('load', handleImage, true);
    this.scroll.addEventListener('error', handleImage, true);
    this.root.addEventListener('click', handleAnchor, true);
    this.root.addEventListener('contextmenu', handleContextMenu);
    this.root.addEventListener('keydown', handleKeyDown);

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
    const { focusedEmoji } = this.state;

    if (!focusedEmoji) {
      return;
    }

    openFromEmojiObject(focusedEmoji, event.currentTarget, event);
  };

  render() {
    const { intl, ...props } = this.props;
    const { focusedEmoji } = this.state;
    const canManage = Boolean(referenceFromPickerEmoji(focusedEmoji));

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
  openFromEmojiObject,
};
