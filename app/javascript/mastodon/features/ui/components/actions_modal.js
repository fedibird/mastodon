import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import StatusContent from '../../../components/status_content';
import Avatar from '../../../components/avatar';
import RelativeTimestamp from '../../../components/relative_timestamp';
import DisplayName from '../../../components/display_name';
import ExternalSourceIdentity, { TimeLink } from '../../../components/external_source_identity';
import { externalIdentityOf } from 'mastodon/external_presentation';
import IconButton from '../../../components/icon_button';
import classNames from 'classnames';

export default class ActionsModal extends ImmutablePureComponent {

  static propTypes = {
    status: ImmutablePropTypes.map,
    actions: PropTypes.array,
    onClick: PropTypes.func,
  };

  renderAction = (action, i) => {
    if (action === null) {
      return <li key={`sep-${i}`} className='dropdown-menu__separator' />;
    }

    const { icon = null, text, meta = null, active = false, href = '#' } = action;

    return (
      <li key={`${text}-${i}`}>
        <a href={href} target='_blank' rel='noopener noreferrer' onClick={this.props.onClick} data-index={i} className={classNames({ active })}>
          {icon && <IconButton title={text} icon={icon} role='presentation' tabIndex='-1' inverted />}
          <div>
            <div className={classNames({ 'actions-modal__item-label': !!meta })}>{text}</div>
            <div>{meta}</div>
          </div>
        </a>
      </li>
    );
  }

  render () {
    const externalIdentity = externalIdentityOf(this.props.status);
    const status = this.props.status && (
      <div className='status light'>
        <div className='boost-modal__status-header'>
          <div className='boost-modal__status-time'>
            <TimeLink url={externalIdentity ? externalIdentity.articleUrl : this.props.status.get('url')} external={!!externalIdentity} className='status__relative-time'>
              <RelativeTimestamp timestamp={this.props.status.get('created_at')} />
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
      <div className='modal-root__modal actions-modal'>
        {status}

        <ul className={classNames({ 'with-status': !!status })}>
          {this.props.actions.map(this.renderAction)}
        </ul>
      </div>
    );
  }

}
