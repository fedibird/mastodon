import React from 'react';
import PropTypes from 'prop-types';
import { injectIntl } from 'react-intl';
import initialState from 'mastodon/initial_state_data';
import EmojiPickerShell from '../emoji_picker_shell';
import { personalEmojiRequest } from './api';
import messages from './messages';

const baseCategories = ['people', 'nature', 'foods', 'activity', 'places', 'objects', 'symbols', 'flags'];
const autoPlayEmoji = initialState?.meta?.auto_play_emoji;
const tones = [
  ['toneDefault', '✋'], ['toneLight', '✋🏻'], ['toneMediumLight', '✋🏼'],
  ['toneMedium', '✋🏽'], ['toneMediumDark', '✋🏾'], ['toneDark', '✋🏿'],
];
let catalogPromise;

function loadCatalog() {
  if (!catalogPromise) {
    catalogPromise = personalEmojiRequest('/api/v1/custom_emojis').then(data => {
      if (!Array.isArray(data)) {
        throw new Error('Invalid custom emoji catalog');
      }

      const visible = data.filter(emoji => emoji.visible_in_picker);

      return {
        custom: visible.map(emoji => ({
          id: emoji.shortcode,
          name: emoji.alternate_name || emoji.shortcode,
          short_names: [emoji.shortcode],
          text: '',
          emoticons: [],
          keywords: [emoji.shortcode, emoji.ruby, emoji.reading, emoji.alternate_name, ...(emoji.aliases || [])].filter(Boolean),
          imageUrl: autoPlayEmoji ? emoji.url : emoji.static_url,
          custom: true,
          customCategory: emoji.category,
        })),
        include: Array.from(new Set(['custom', ...visible.map(emoji => emoji.category ? `custom-${emoji.category}` : 'custom')])).concat(baseCategories),
      };
    }).catch(error => {
      catalogPromise = null;
      throw error;
    });
  }

  return catalogPromise;
}

// This entire module, its Nimble dataset, and the custom catalog are loaded
// only for the add dialog or an explicitly selected standard preview.
class StandardPicker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    onPick: PropTypes.func.isRequired,
    emojiSize: PropTypes.number,
    autoFocus: PropTypes.bool,
    theme: PropTypes.string,
    skinTone: PropTypes.number.isRequired,
    onSkinToneChange: PropTypes.func.isRequired,
  };

  static defaultProps = { emojiSize: 22, autoFocus: false, theme: 'dark' };

  state = { catalog: null, error: false };

  componentDidMount() {
    this.mounted = true;
    this.load();
  }

  componentWillUnmount() {
    this.mounted = false;
  }

  load = () => {
    this.setState({ error: false });
    loadCatalog().then(catalog => {
      if (this.mounted) {
        this.setState({ catalog });
      }
    }).catch(() => {
      if (this.mounted) {
        this.setState({ error: true });
      }
    });
  };

  handleSkin = event => this.props.onSkinToneChange(Number(event.target.value));

  render() {
    const { intl, onPick, emojiSize, autoFocus, theme, skinTone } = this.props;
    const { catalog, error } = this.state;

    if (error) {
      return <div className='pes-empty' role='status'><p>{intl.formatMessage(messages.standardError)}</p><button type='button' className='pes-button' onClick={this.load}>{intl.formatMessage(messages.retry)}</button></div>;
    }

    if (!catalog) {
      return <p className='pes-empty' role='status'>{intl.formatMessage(messages.standardLoading)}</p>;
    }

    return (
      <div className='pes-standard-picker'>
        <label className='pes-tone-label'>
          <span>{intl.formatMessage(messages.skinTone)}</span>
          {/* A controlled tone change previews the selected tone without navigation. */}
          {/* eslint-disable-next-line jsx-a11y/no-onchange */}
          <select className='pes-select pes-tone' value={skinTone} onChange={this.handleSkin}>
            {tones.map(([label, glyph], index) => <option key={label} value={index + 1}>{glyph} {intl.formatMessage(messages[label])}</option>)}
          </select>
        </label>
        <EmojiPickerShell
          open
          personalEnabled={false}
          initialMode='standard'
          emojiSize={emojiSize}
          perLine={Math.max(1, Math.floor(272 / (emojiSize + 12)))}
          autoFocus={autoFocus}
          theme={theme}
          onPick={onPick}
          standardPickerProps={{
            ...catalog,
            skin: skinTone,
            showPreview: false,
            showSkinTones: false,
            emojiTooltip: true,
            i18n: {
              search: intl.formatMessage(messages.search),
              categorieslabel: intl.formatMessage(messages.categories),
              categories: {
                recent: intl.formatMessage(messages.recent),
                search: intl.formatMessage(messages.searchResults),
                custom: intl.formatMessage(messages.custom),
                people: intl.formatMessage(messages.people),
                nature: intl.formatMessage(messages.nature),
                foods: intl.formatMessage(messages.food),
                activity: intl.formatMessage(messages.activity),
                places: intl.formatMessage(messages.travel),
                objects: intl.formatMessage(messages.objects),
                symbols: intl.formatMessage(messages.symbols),
                flags: intl.formatMessage(messages.flags),
              },
            },
          }}
        />
      </div>
    );
  }

}

export default injectIntl(StandardPicker);
