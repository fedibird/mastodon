import { connect } from 'react-redux';
import { Component } from 'react';
import PropTypes from 'prop-types';
import { selectAcceptedPreferenceDocument } from 'mastodon/selectors/user_preferences';
import { applyAcceptedAppearance, browserAppearanceTarget } from 'mastodon/utils/appearance_preferences';

// Mounted beside the columns, not around them, so a preference update cannot
// remount the composer, timelines, or modals.
export class AppearancePreferences extends Component {

  static propTypes = {
    document: PropTypes.object,
  };

  componentDidMount () {
    this.apply();
  }

  componentDidUpdate (prevProps) {
    if (prevProps.document !== this.props.document) {
      this.apply();
    }
  }

  apply () {
    if (!this.props.document) {
      return;
    }

    applyAcceptedAppearance(this.props.document, browserAppearanceTarget());
  }

  render () {
    return null;
  }

}

const mapStateToProps = state => ({
  document: selectAcceptedPreferenceDocument(state),
});

export default connect(mapStateToProps)(AppearancePreferences);
