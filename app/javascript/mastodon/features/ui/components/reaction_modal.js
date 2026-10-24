import React, { forwardRef } from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import StatusContent from '../../../components/status_content';
import Avatar from '../../../components/avatar';
import AbsoluteTimestamp from '../../../components/absolute_timestamp';
import RelativeTimestamp from '../../../components/relative_timestamp';
import DisplayName from '../../../components/display_name';
import ExternalSourceIdentity from '../../../components/external_source_identity';
import { externalIdentityOf } from 'mastodon/external_presentation';
import emojiCompressed from 'mastodon/features/emoji/emoji_compressed';
import classNames from 'classnames';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { supportsPassiveEvents } from 'detect-passive-events';
import { EmojiPicker as EmojiPickerAsync } from '../util/async-components';
import { assetHost } from 'mastodon/utils/config';
import { pickerEmojiSize, disableRelativeTime } from 'mastodon/initial_state';

const nimblePickerData = emojiCompressed[5];

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
    placement: PropTypes.string,
    arrowOffsetLeft: PropTypes.string,
    arrowOffsetTop: PropTypes.string,
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
      e.stopPropagation();
      e.preventDefault();
      this.props.onClose();
    }
  }

  componentDidMount () {
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, { passive: false });
  }

  componentWillUnmount () {
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

  render () {
    const { loading, style, intl, skinTone, frequentlyUsedEmojis, pickersEmoji } = this.props;

    if (loading) {
      return <div style={{ width: '100%' ,height: '50%'}} />;
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
          emojiTooltip
          style={{width: '100%'}}
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

const mapStateToProps = state => ({
  skinTone: state.getIn(['settings', 'skinTone']),
});

class ReactionModal extends ImmutablePureComponent {

  static propTypes = {
    status: ImmutablePropTypes.map,
    pickersEmoji: ImmutablePropTypes.map,
    onPickEmoji: PropTypes.func.isRequired,
    onSkinTone: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    skinTone: PropTypes.number.isRequired,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
  };

  state = {
    loading: true,
  };

  componentDidMount() {
    this.setState({ loading: true });
    EmojiPickerAsync().then(EmojiMart => {
      EmojiPicker = EmojiMart.Picker;
      Emoji = EmojiMart.Emoji;
      this.setState({ loading: false });
    }).catch(() => {
      this.setState({ loading: false });
    });
  }

  render () {
    const { pickersEmoji, onPickEmoji, onSkinTone, onClose, skinTone, frequentlyUsedEmojis } = this.props;
    const loading = this.state.loading;
    const externalIdentity = externalIdentityOf(this.props.status);
    const status = this.props.status && (
      <div className='status light'>
        <div className='boost-modal__status-header'>
          <div className='boost-modal__status-time'>
            <a href={this.props.status.get('url')} className='status__relative-time' target='_blank' rel='noopener noreferrer'>
              {disableRelativeTime ? <AbsoluteTimestamp timestamp={this.props.status.get('created_at')} /> : <RelativeTimestamp timestamp={this.props.status.get('created_at')} /> }
            </a>
          </div>

          {externalIdentity ? (
            <ExternalSourceIdentity identity={externalIdentity} size={48} className='status__display-name' avatarClassName='status__avatar' />
          ) : (
            <a href={this.props.status.getIn(['account', 'url'])} className='status__display-name'>
              <div className='status__avatar'>
                <Avatar account={this.props.status.get('account')} size={48} />
              </div>

              <DisplayName account={this.props.status.get('account')} />
            </a>
          )}
        </div>

        <StatusContent status={this.props.status} />
      </div>
    );

    return (
      <div className='modal-root__modal reaction-modal'>
        {status}
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

export default connect(mapStateToProps, null, null, { forwardRef: true })(ReactionModal);
