import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import IconButton from '../../../components/icon_button';
import DisplayName from '../../../components/display_name';
import RelativeTimestamp from '../../../components/relative_timestamp';
import emojify from '../../emoji/emoji';

const mapStateToProps = (state, { statusId }) => ({
  language: state.getIn(['statuses', statusId, 'language']),
  versions: state.getIn(['history', statusId, 'items'], ImmutableList()),
  accounts: state.get('accounts'),
});

class CompareHistoryModal extends React.PureComponent {

  static propTypes = {
    onClose: PropTypes.func.isRequired,
    index: PropTypes.number.isRequired,
    statusId: PropTypes.string.isRequired,
    language: PropTypes.string,
    versions: ImmutablePropTypes.list,
    accounts: ImmutablePropTypes.map,
  };

  render () {
    const { index, versions, language, onClose, accounts } = this.props;
    const currentVersion = versions && versions.get(index);

    if (!currentVersion) {
      return (
        <div className='modal-root__modal compare-history-modal'>
          <div className='report-modal__target'>
            <IconButton className='report-modal__close' title='Close' icon='times' onClick={onClose} size={20} />
            <FormattedMessage id='status.history.empty' defaultMessage='No edit history' />
          </div>
        </div>
      );
    }

    const emojiMap = (currentVersion.get('emojis') || ImmutableList()).reduce((obj, emoji) => {
      obj[`:${emoji.get('shortcode')}:`] = emoji.toJS();
      return obj;
    }, {});
    const content = { __html: emojify(currentVersion.get('content') || '', emojiMap) };
    const account = accounts && accounts.get(currentVersion.get('account'));
    const formattedDate = <RelativeTimestamp timestamp={currentVersion.get('created_at')} short={false} />;
    const formattedName = account ? <DisplayName account={account} /> : null;
    const label = currentVersion.get('original') ? (
      <FormattedMessage id='status.history.created' defaultMessage='{name} created {date}' values={{ name: formattedName, date: formattedDate }} />
    ) : (
      <FormattedMessage id='status.history.edited' defaultMessage='{name} edited {date}' values={{ name: formattedName, date: formattedDate }} />
    );
    const media = currentVersion.get('media_attachments') || ImmutableList();

    return (
      <div className='modal-root__modal compare-history-modal'>
        <div className='report-modal__target'>
          <IconButton className='report-modal__close' title='Close' icon='times' onClick={onClose} size={20} />
          {label}
        </div>

        <div className='compare-history-modal__container'>
          <div className='status__content'>
            {currentVersion.get('spoiler_text') && currentVersion.get('spoiler_text').length > 0 && (
              <React.Fragment>
                <div className='translate' lang={language}>{currentVersion.get('spoiler_text')}</div>
                <hr />
              </React.Fragment>
            )}

            <div className='status__content__text status__content__text--visible translate' dangerouslySetInnerHTML={content} lang={language} />

            {currentVersion.get('sensitive') && (
              <p className='compare-history-modal__sensitive'>
                <FormattedMessage id='status.history.sensitive' defaultMessage='Marked as sensitive' />
              </p>
            )}

            {!!currentVersion.get('poll') && (
              <ul className='compare-history-modal__poll'>
                {currentVersion.getIn(['poll', 'options']).map(option => (
                  <li key={option.get('title')}>{option.get('title')}</li>
                ))}
              </ul>
            )}

            {media.size > 0 && (
              <ul className='compare-history-modal__media'>
                {media.map(item => (
                  <li key={item.get('id')}>
                    <FormattedMessage id='status.history.media_description' defaultMessage='Media description: {description}' values={{ description: item.get('description') || '' }} />
                  </li>
                ))}
              </ul>
            )}

            <p className='compare-history-modal__created'>
              <FormattedMessage id='status.history.revision_time' defaultMessage='Revision time: {date}' values={{ date: formattedDate }} />
            </p>
          </div>
        </div>
      </div>
    );
  }

}

export default connect(mapStateToProps)(CompareHistoryModal);
