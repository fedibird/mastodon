import React from 'react';
import ReactDOM from 'react-dom';
import PropTypes from 'prop-types';
import { IntlProvider, addLocaleData, defineMessages, injectIntl } from 'react-intl';
import { fromJS, List as ImmutableList, Map as ImmutableMap } from 'immutable';
import ImmutablePropTypes from 'react-immutable-proptypes';
import escapeTextContentForBrowser from 'escape-html';

import Icon from 'mastodon/components/icon';
import CustomEmojiText from 'mastodon/components/custom_emoji_text';
import EmojiPickerDropdown from 'mastodon/features/compose/components/emoji_picker_dropdown';
import emojify, {
  buildCustomEmojiMap,
  buildCustomEmojis,
  categoriesFromEmojis,
} from 'mastodon/features/emoji/emoji';
import { getLocale } from 'mastodon/locales';

const messages = defineMessages({
  emoji: { id: 'emoji_button.label', defaultMessage: 'Insert emoji' },
});

let customEmojiPromise;

const emptyEmojiData = {
  all: ImmutableList(),
  picker: ImmutableMap({
    custom_emojis: [],
    categories: new Set(['custom']),
  }),
};

let cachedCustomEmojis = emptyEmojiData.all;

const getCustomEmojiData = () => {
  if (!customEmojiPromise) {
    customEmojiPromise = fetch('/api/v1/custom_emojis', {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    }).then(response => {
      if (!response.ok) {
        throw new Error(response.status);
      }

      return response.json();
    }).then(data => {
      const all = fromJS(Array.isArray(data) ? data : []);
      const visible = all.filter(emoji => emoji.get('visible_in_picker'));

      cachedCustomEmojis = all;

      return {
        all,
        picker: ImmutableMap({
          custom_emojis: buildCustomEmojis(visible),
          categories: categoriesFromEmojis(visible),
        }),
      };
    });
  }

  return customEmojiPromise;
};

// Live profile-card display name. The editable value stays canonical; only
// this rendered node is emojified, using the same escaped emojify path as
// the field preview.
export const renderProfileCardDisplayName = (name, value, fallback = '') => {
  if (!name) {
    return;
  }

  if (value) {
    name.innerHTML = emojify(
      escapeTextContentForBrowser(value),
      buildCustomEmojiMap(cachedCustomEmojis),
    );
    return;
  }

  name.textContent = fallback;
};

export const insertEmojiAtSelection = (field, emoji, selection) => {
  const value = field.value;
  const start = selection?.start ?? field.selectionStart ?? value.length;
  const end = selection?.end ?? field.selectionEnd ?? start;
  const nextValue = `${value.slice(0, start)}${emoji}${value.slice(end)}`;

  if (field.maxLength > 0 && nextValue.length > field.maxLength) {
    return false;
  }

  field.value = nextValue;
  const position = start + emoji.length;
  field.focus();
  field.setSelectionRange(position, position);
  field.dispatchEvent(new Event('input', { bubbles: true }));

  return true;
};

const renderCustomEmojiText = (nodes, emojis) => {
  const emojiMap = buildCustomEmojiMap(emojis);

  nodes.forEach(node => {
    node.innerHTML = emojify(
      escapeTextContentForBrowser(node.textContent),
      emojiMap,
    );
  });
};

export const decorateEmojiPickerField = field => {
  if (field.dataset.emojiPickerMounted === 'true') {
    return field.parentElement.querySelector('.emoji-picker-input__button-host');
  }

  const fieldWrap = document.createElement('div');
  fieldWrap.className = 'emoji-picker-field';

  const wrapper = document.createElement('div');
  wrapper.className = 'emoji-picker-input';

  if (field.tagName === 'TEXTAREA') {
    wrapper.classList.add('emoji-picker-input--textarea');
  }

  const host = document.createElement('div');
  host.className = 'emoji-picker-input__button-host';

  const preview = document.createElement('div');
  preview.className = 'emoji-picker-preview';

  field.parentNode.insertBefore(fieldWrap, field);
  fieldWrap.appendChild(wrapper);
  wrapper.appendChild(field);
  wrapper.appendChild(host);
  fieldWrap.appendChild(preview);
  field.dataset.emojiPickerMounted = 'true';

  return host;
};

class FormEmojiPickerField extends React.PureComponent {

  state = {
    value: this.props.field.value,
  };

  componentDidMount () {
    this.props.field.addEventListener('input', this.handleInput);
    this.syncPreviewState();
  }

  componentDidUpdate (prevProps, prevState) {
    if (prevState.value !== this.state.value || prevProps.customEmojis !== this.props.customEmojis) {
      this.syncCardDisplayName();
    }
  }

  componentWillUnmount () {
    this.props.field.removeEventListener('input', this.handleInput);
  }

  syncPreviewState = () => {
    const fieldWrap = this.props.field.parentElement && this.props.field.parentElement.parentElement;

    if (!fieldWrap) {
      return;
    }

    fieldWrap.classList.toggle(
      'emoji-picker-field--has-preview',
      this.props.field.value.length > 0,
    );
  };

  handleInput = () => {
    this.syncPreviewState();
    this.setState({ value: this.props.field.value });
  };

  syncCardDisplayName = () => {
    if (this.props.field.id !== 'account_display_name') {
      return;
    }

    const name = document.querySelector('.card .display-name strong');

    renderProfileCardDisplayName(name, this.props.field.value, this.props.field.dataset.default);
  };

  handleOpen = id => {
    this.props.onOpen(this.props.field, id);
  };

  handlePick = emoji => {
    this.props.onPick(this.props.field, emoji);
  };

  handleMouseDown = () => {
    this.props.onSaveSelection(this.props.field);
  };

  render () {
    const { field, index, intl, openDropdownId, pickerData, customEmojis, onClose, skinTone, onSkinTone } = this.props;
    const host = decorateEmojiPickerField(field);
    const preview = field.parentElement.parentElement.querySelector('.emoji-picker-preview');
    const label = intl.formatMessage(messages.emoji);
    const { value } = this.state;

    return (
      <React.Fragment>
        {ReactDOM.createPortal(
          <EmojiPickerDropdown
            key={`form-emoji-picker-${index}`}
            pickersEmoji={pickerData}
            openDropdownId={openDropdownId}
            onOpen={this.handleOpen}
            onClose={onClose}
            onPickEmoji={this.handlePick}
            skinTone={skinTone}
            onSkinTone={onSkinTone}
            frequentlyUsedEmojis={[]}
            button={(
              <button
                type='button'
                className='icon-button'
                title={label}
                aria-label={label}
                onMouseDown={this.handleMouseDown}
              >
                <Icon id='smile-o' fixedWidth aria-hidden='true' />
              </button>
            )}
          />,
          host,
        )}
        {value && preview && ReactDOM.createPortal(
          <CustomEmojiText text={value} customEmojis={customEmojis} />,
          preview,
        )}
      </React.Fragment>
    );
  }

}

FormEmojiPickerField.propTypes = {
  field: PropTypes.instanceOf(HTMLElement).isRequired,
  index: PropTypes.number.isRequired,
  intl: PropTypes.object.isRequired,
  openDropdownId: PropTypes.string,
  pickerData: ImmutablePropTypes.map.isRequired,
  customEmojis: ImmutablePropTypes.list.isRequired,
  skinTone: PropTypes.number.isRequired,
  onOpen: PropTypes.func.isRequired,
  onClose: PropTypes.func.isRequired,
  onPick: PropTypes.func.isRequired,
  onSkinTone: PropTypes.func.isRequired,
  onSaveSelection: PropTypes.func.isRequired,
};

class FormEmojiPickerManager extends React.PureComponent {

  state = {
    openDropdownId: null,
    skinTone: 1,
    pickerData: emptyEmojiData.picker,
    customEmojis: emptyEmojiData.all,
  };

  selections = new WeakMap();

  componentDidMount () {
    const { fields, textNodes } = this.props;
    this.mounted = true;

    fields.forEach(field => {
      const saveSelection = () => this.saveSelection(field);
      field.addEventListener('select', saveSelection);
      field.addEventListener('keyup', saveSelection);
      field.addEventListener('click', saveSelection);
      field.addEventListener('focus', saveSelection);
    });

    getCustomEmojiData().then(({ all, picker }) => {
      renderCustomEmojiText(textNodes, all);

      if (!this.mounted) {
        return;
      }

      this.setState({
        pickerData: picker,
        customEmojis: all,
      });
    }).catch(() => {
      // The field and Unicode picker remain usable if custom emoji loading fails.
    });
  }

  componentWillUnmount () {
    this.mounted = false;
  }

  saveSelection = field => {
    this.selections.set(field, {
      start: field.selectionStart,
      end: field.selectionEnd,
    });
  };

  handleOpen = (field, id) => {
    this.saveSelection(field);
    this.setState({ openDropdownId: id });
  };

  handleClose = id => {
    if (this.state.openDropdownId === id) {
      this.setState({ openDropdownId: null });
    }
  };

  handlePick = (field, emoji) => {
    insertEmojiAtSelection(field, emoji.native, this.selections.get(field));
    this.saveSelection(field);
  };

  handleSkinTone = skinTone => {
    this.setState({ skinTone });
  };

  renderPicker = (field, index) => (
    <FormEmojiPickerField
      key={`form-emoji-picker-${index}`}
      field={field}
      index={index}
      intl={this.props.intl}
      pickerData={this.state.pickerData}
      customEmojis={this.state.customEmojis}
      openDropdownId={this.state.openDropdownId}
      onOpen={this.handleOpen}
      onClose={this.handleClose}
      onPick={this.handlePick}
      skinTone={this.state.skinTone}
      onSkinTone={this.handleSkinTone}
      onSaveSelection={this.saveSelection}
    />
  );

  render () {
    return this.props.fields.map(this.renderPicker);
  }

}

FormEmojiPickerManager.propTypes = {
  fields: PropTypes.arrayOf(PropTypes.instanceOf(HTMLElement)).isRequired,
  textNodes: PropTypes.arrayOf(PropTypes.instanceOf(HTMLElement)).isRequired,
  intl: PropTypes.object.isRequired,
};

const ConnectedManager = injectIntl(FormEmojiPickerManager);

export const initializeFormEmojiPickers = ({
  fields = Array.from(document.querySelectorAll('input[type="text"][data-emoji-picker], input[type="search"][data-emoji-picker], textarea[data-emoji-picker]')),
  textNodes = Array.from(document.querySelectorAll('[data-custom-emoji-text]')),
  locale = document.documentElement.lang,
} = {}) => {
  const undecoratedFields = fields.filter(field => field.dataset.emojiPickerMounted !== 'true');
  const unrenderedTextNodes = textNodes.filter(node => node.dataset.customEmojiRendered !== 'true');

  if (undecoratedFields.length === 0 && unrenderedTextNodes.length === 0) {
    return null;
  }

  unrenderedTextNodes.forEach(node => {
    node.dataset.customEmojiRendered = 'true';
  });

  const { localeData, messages: localeMessages } = getLocale();
  addLocaleData(localeData);

  const root = document.createElement('div');
  root.className = 'form-emoji-picker-root';
  document.body.appendChild(root);

  ReactDOM.render(
    <IntlProvider locale={locale} messages={localeMessages}>
      <ConnectedManager fields={undecoratedFields} textNodes={unrenderedTextNodes} />
    </IntlProvider>,
    root,
  );

  return root;
};

export const resetCustomEmojiPromiseForTests = () => {
  customEmojiPromise = undefined;
  cachedCustomEmojis = emptyEmojiData.all;
};
