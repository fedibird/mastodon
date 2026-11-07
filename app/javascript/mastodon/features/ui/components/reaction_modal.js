import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import StatusContent from '../../../components/status_content';
import Avatar from '../../../components/avatar';
import AbsoluteTimestamp from '../../../components/absolute_timestamp';
import RelativeTimestamp from '../../../components/relative_timestamp';
import DisplayName from '../../../components/display_name';
import ExternalSourceIdentity, { TimeLink } from '../../../components/external_source_identity';
import { externalIdentityOf } from 'mastodon/external_presentation';
import { disableRelativeTime } from 'mastodon/initial_state';
import { ensureCustomEmojis } from 'mastodon/actions/custom_emojis';
import { getFrequentlyUsedEmojis, getPickersEmoji } from 'mastodon/selectors';
import EmojiPickerPanel from 'mastodon/features/emoji/emoji_picker_panel';

const mapStateToProps = state => ({
  skinTone: state.getIn(['settings', 'skinTone']),
  pickersEmoji: getPickersEmoji(state),
  frequentlyUsedEmojis: getFrequentlyUsedEmojis(state),
});

const mapDispatchToProps = dispatch => ({
  onStandardActive: () => dispatch(ensureCustomEmojis()),
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
    onStandardActive: PropTypes.func,
  };

  handlePick = (emoji) => {
    this.props.onPickEmoji(emoji);
  };

  render () {
    const { pickersEmoji, onSkinTone, onClose, skinTone, frequentlyUsedEmojis, onStandardActive } = this.props;
    const externalIdentity = externalIdentityOf(this.props.status);
    const status = this.props.status && (
      <div className='status light'>
        <div className='boost-modal__status-header'>
          <div className='boost-modal__status-time'>
            <TimeLink url={externalIdentity ? externalIdentity.articleUrl : this.props.status.get('url')} external={!!externalIdentity} className='status__relative-time'>
              {disableRelativeTime ? <AbsoluteTimestamp timestamp={this.props.status.get('created_at')} /> : <RelativeTimestamp timestamp={this.props.status.get('created_at')} /> }
            </TimeLink>
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
        <EmojiPickerPanel
          notFoundVariant='reaction'
          autoFocus={false}
          pickersEmoji={pickersEmoji}
          onPick={this.handlePick}
          onRequestClose={onClose}
          onSkinTone={onSkinTone}
          skinTone={skinTone}
          frequentlyUsedEmojis={frequentlyUsedEmojis}
          onStandardActive={onStandardActive}
        />
      </div>
    );
  }

}

export default connect(mapStateToProps, mapDispatchToProps, null, { forwardRef: true })(ReactionModal);
