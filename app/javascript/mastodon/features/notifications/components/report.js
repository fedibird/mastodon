import React, { Fragment } from 'react';
import PropTypes from 'prop-types';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import AvatarOverlay from 'mastodon/components/avatar_overlay';
import RelativeTimestamp from 'mastodon/components/relative_timestamp';

const messages = defineMessages({
  openReport: { id: 'report_notification.open', defaultMessage: 'Open report' },
  other: { id: 'report_notification.categories.other', defaultMessage: 'Other' },
  spam: { id: 'report_notification.categories.spam', defaultMessage: 'Spam' },
  legal: { id: 'report_notification.categories.legal', defaultMessage: 'Legal' },
  violation: { id: 'report_notification.categories.violation', defaultMessage: 'Rule violation' },
});

const attachedStatusCount = (report) => {
  const statusIds = report.get('status_ids');

  if (!statusIds) {
    return 0;
  }

  if (typeof statusIds.size === 'number') {
    return statusIds.size;
  }

  if (typeof statusIds.length === 'number') {
    return statusIds.length;
  }

  return 0;
};

const categoryMessage = (category) => messages[category] || messages.other;

class Report extends ImmutablePureComponent {

  static propTypes = {
    account: ImmutablePropTypes.map,
    report: ImmutablePropTypes.map,
    hidden: PropTypes.bool,
    intl: PropTypes.object.isRequired,
  };

  render () {
    const { intl, hidden, report, account } = this.props;

    if (!report) {
      return null;
    }

    if (hidden) {
      return <Fragment>{report.get('id')}</Fragment>;
    }

    const targetAccount = report.get('target_account');
    const createdAt = report.get('created_at');

    return (
      <div className='notification__report'>
        <div className='notification__report__avatar'>
          {targetAccount && account && (
            <AvatarOverlay account={targetAccount} friend={account} />
          )}
        </div>

        <div className='notification__report__details'>
          <div>
            {createdAt && <RelativeTimestamp timestamp={createdAt} />}
            {createdAt && ' · '}
            <FormattedMessage
              id='report_notification.attached_statuses'
              defaultMessage='{count, plural, one {{count} post} other {{count} posts}} attached'
              values={{ count: attachedStatusCount(report) }}
            />
            <br />
            <strong>{intl.formatMessage(categoryMessage(report.get('category')))}</strong>
          </div>

          <div className='notification__report__actions'>
            <a href={`/admin/reports/${report.get('id')}`} className='button' target='_blank' rel='noopener noreferrer'>
              {intl.formatMessage(messages.openReport)}
            </a>
          </div>
        </div>
      </div>
    );
  }

}

export default injectIntl(Report);
