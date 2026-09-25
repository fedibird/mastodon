import React from 'react';
import ReactDOM from 'react-dom';
import PropTypes from 'prop-types';
import { IntlProvider, addLocaleData, defineMessages, injectIntl } from 'react-intl';
import { fromJS, List as ImmutableList, Map as ImmutableMap } from 'immutable';
import ImmutablePropTypes from 'react-immutable-proptypes';
import escapeTextContentForBrowser from 'escape-html';

import Icon from 'mastodon/components/icon';
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

  const wrapper = document.createElement('div');
  wrapper.className = 'emoji-picker-input';

  if (field.tagName === 'TEXTAREA') {
    wrapper.classList.add('emoji-picker-input--textarea');
  }

  const host = document.createElement('span');
  host.className = 'emoji-picker-input__button-host';

  field.parentNode.insertBefore(wrapper, field);
  wrapper.appendChild(field);
  wrapper.appendChild(host);
  field.dataset.emojiPickerMounted = 'true';

  return host;
};

class FormEmojiPickerField extends React.PureComponent {

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
    const { field, index, intl, openDropdownId, pickerData, onClose, skinTone, onSkinTone } = this.props;
    const host = decorateEmojiPickerField(field);
    const label = intl.formatMessage(messages.emoji);

    return ReactDOM.createPortal(
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
    );
  }

}

FormEmojiPickerField.propTypes = {
  field: PropTypes.instanceOf(HTMLElement).isRequired,
  index: PropTypes.number.isRequired,
  intl: PropTypes.object.isRequired,
  openDropdownId: PropTypes.string,
  pickerData: ImmutablePropTypes.map.isRequired,
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
  };

  selections = new WeakMap();

  componentDidMount () {
    const { fields, textNodes } = this.props;

    fields.forEach(field => {
      const saveSelection = () => this.saveSelection(field);
      field.addEventListener('select', saveSelection);
      field.addEventListener('keyup', saveSelection);
      field.addEventListener('click', saveSelection);
      field.addEventListener('focus', saveSelection);
    });

    getCustomEmojiData().then(({ all, picker }) => {
      renderCustomEmojiText(textNodes, all);
      this.setState({ pickerData: picker });
    }).catch(() => {
      // The field and Unicode picker remain usable if custom emoji loading fails.
    });
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
};
