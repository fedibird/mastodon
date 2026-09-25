import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import StatusHistoryRevision from 'mastodon/components/status_history_revision';

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
    const account = currentVersion && accounts && accounts.get(currentVersion.get('account'));

    return (
      <StatusHistoryRevision
        revision={currentVersion}
        account={account}
        language={language}
        onClose={onClose}
      />
    );
  }

}

export default connect(mapStateToProps)(CompareHistoryModal);
