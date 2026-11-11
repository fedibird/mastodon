import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { ThumbnailGallery } from 'mastodon/features/ui/util/async-components';
import IconButton from 'mastodon/components/icon_button';
import { injectIntl, defineMessages } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { HotKeys } from 'react-hotkeys';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import { EmojiMutedPreview } from 'mastodon/components/emoji_muted_html';

// We use the component (and not the container) since we do not want
// to use the progress bar to show download progress
import Bundle from 'mastodon/features/ui/components/bundle';

const messages = defineMessages({
  unselect: { id: 'reference_stack.unselect', defaultMessage: 'Unselecting a post' },
});

const dateFormatOptions = {
  hour12: false,
  year: 'numeric',
  month: 'short',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
};

export default @injectIntl
class ScheduledStatus extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    scheduledStatus: ImmutablePropTypes.map,
    onDelete: PropTypes.func,
    onMoveUp: PropTypes.func,
    onMoveDown: PropTypes.func,
    onDeleteScheduledStatus: PropTypes.func,
    onRedraftScheduledStatus: PropTypes.func,
  };

  handleHotkeyMoveUp = () => {
    this.props.onMoveUp(this.props.scheduledStatus.get('id'));
  }

  handleHotkeyMoveDown = () => {
    this.props.onMoveDown(this.props.scheduledStatus.get('id'));
  }

  handleDeleteClick = (e) => {
    const { scheduledStatus, onDeleteScheduledStatus } = this.props;

    e.stopPropagation();

    onDeleteScheduledStatus(scheduledStatus.get('id'), e);
  }

  handleClick = (e) => {
    const { scheduledStatus, onRedraftScheduledStatus } = this.props;

    e.stopPropagation();

    onRedraftScheduledStatus(scheduledStatus, this.context.router.history, e);
  }

  handleRef = c => {
    this.node = c;
  }

  render () {
    const { intl, scheduledStatus } = this.props;

    if (scheduledStatus === null) {
      return null;
    }

    const handlers = {
      moveUp: this.handleHotkeyMoveUp,
      moveDown: this.handleHotkeyMoveDown,
    };

    return (
      <HotKeys handlers={handlers}>
        <div className={classNames('mini-status__wrapper', `mini-status__wrapper-${scheduledStatus.getIn(['params', 'visibility'])}`, 'focusable', { 'mini-status__wrapper-reply': !!scheduledStatus.getIn(['params', 'in_reply_to_id']) })} role='button' tabIndex={0} onClick={this.handleClick} ref={this.handleRef}>
          <div className={classNames('mini-status', `mini-status-${scheduledStatus.getIn(['params', 'visibility'])}`, { 'mini-status-reply': !!scheduledStatus.getIn(['params', 'in_reply_to_id']) })} data-id={scheduledStatus.get('id')}>
            <div className='mini-status__content'>
              <EmojiMutedPreview tag='div' className='mini-status__content__text translate' lang={scheduledStatus.getIn(['params', 'language'])} text={scheduledStatus.getIn(['params', 'text']) || ''} />
              <Bundle fetchComponent={ThumbnailGallery} loading={this.renderLoadingMediaGallery}>
                {Component => <Component media={scheduledStatus.get('media_attachments')} />}
              </Bundle>
              <div className='mini-status__scheduled-time'>
                <Icon id='clock-o' fixedWidth />
                {intl.formatDate(scheduledStatus.get('scheduled_at'), dateFormatOptions)}
              </div>
            </div>
            <div className='mini-status__unselect'><IconButton title={intl.formatMessage(messages.unselect)} icon='times' onClick={this.handleDeleteClick} /></div>
          </div>
        </div>
      </HotKeys>
    );
  }

}
