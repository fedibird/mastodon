import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import Avatar from './avatar';
import { ExternalSourceIcon } from './external_source_identity';
import { externalIdentityOf, externalIdentityName } from '../external_presentation';
import { injectIntl, defineMessages } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { ThumbnailGallery } from '../features/ui/util/async-components';
import classNames from 'classnames';
import IconButton from '../components/icon_button';

// We use the component (and not the container) since we do not want
// to use the progress bar to show download progress
import Bundle from '../features/ui/components/bundle';

const messages = defineMessages({
  unselect: { id: 'reference_stack.unselect', defaultMessage: 'Unselecting a post' },
});

export default @injectIntl
class StatusItem extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    status: ImmutablePropTypes.map,
    onClick: PropTypes.func,
    onUnselectReference: PropTypes.func,
  };

  updateOnProps = [
    'status',
  ];

  handleClick = () => {
    if (this.props.onClick) {
      this.props.onClick();
      return;
    }

    if (!this.context.router) {
      return;
    }

    const { status } = this.props;
    this.context.router.history.push(`/statuses/${status.get('id')}`);
  }

  handleAccountClick = (e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      const id = e.currentTarget.getAttribute('data-id');
      const group = e.currentTarget.getAttribute('data-group') !== 'false';

      e.preventDefault();
      e.stopPropagation();

      if (group) {
        this.context.router.history.push(`/timelines/groups/${id}`);
      } else {
        this.context.router.history.push(`/accounts/${id}`);
      }
    }
  }

  handleUnselectClick = (e) => {
    const { status, onUnselectReference } = this.props;
    const id = status.get('id');

    e.stopPropagation();
    onUnselectReference(id, e);
  }

  handleRef = c => {
    this.node = c;
  }

  render () {
    const { intl, status } = this.props;

    if (status === null) {
      return null;
    }

    const externalIdentity = externalIdentityOf(status);

    return (
      <div className={classNames('mini-status__wrapper', `mini-status__wrapper-${status.get('visibility')}`, { 'mini-status__wrapper-reply': !!status.get('in_reply_to_id') })} ref={this.handleRef}>
        <div className={classNames('mini-status', `mini-status-${status.get('visibility')}`, { 'mini-status-reply': !!status.get('in_reply_to_id') })} onClick={this.handleClick} role='button' tabIndex={0} data-id={status.get('id')}>
          <div className='mini-status__account'>
            {externalIdentity ? (
              <span className='status__display-name' title={externalIdentityName(intl, externalIdentity)}>
                <div className='mini-status__avatar'>
                  <ExternalSourceIcon iconId={externalIdentity.iconId} iconUrl={externalIdentity.iconUrl} size={24} />
                </div>
              </span>
            ) : (
              <a onClick={this.handleAccountClick} data-id={status.getIn(['account', 'id'])} data-group={status.getIn(['account', 'group'])} href={status.getIn(['account', 'url'])} title={status.getIn(['account', 'acct'])} className='status__display-name' target='_blank' rel='noopener noreferrer'>
                <div className='mini-status__avatar'>
                  <Avatar account={status.get('account')} size={24} />
                </div>
              </a>
            )}
          </div>

          <div className='mini-status__content'>
            <div className='mini-status__content__text translate' lang={status.get('language')} dangerouslySetInnerHTML={{ __html: status.get('shortHtml') }} />
            <Bundle fetchComponent={ThumbnailGallery} loading={this.renderLoadingMediaGallery}>
              {Component => (
                <Component
                  media={status.get('media_attachments')}
                  sensitive={status.get('sensitive')}
                />
              )}
            </Bundle>
          </div>
          <div className='mini-status__unselect'><IconButton title={intl.formatMessage(messages.unselect)} icon='times' onClick={this.handleUnselectClick} /></div>
        </div>
      </div>
    );
  }

}
