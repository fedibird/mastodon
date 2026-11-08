import React from 'react';
import PropTypes from 'prop-types';
import { injectIntl } from 'react-intl';
import messages from './messages';

export const loadEditorStandardPicker = () => import(/* webpackChunkName: "personal_emoji_sets_standard" */ './standard_picker');

class LazyStandardPicker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    load: PropTypes.func,
    onPick: PropTypes.func.isRequired,
    emojiSize: PropTypes.number,
    autoFocus: PropTypes.bool,
    showFrequentlyUsed: PropTypes.bool,
  };

  static defaultProps = { load: loadEditorStandardPicker };

  state = { Component: null, error: false };

  componentDidMount() {
    this.mounted = true;
    this.load();
  }

  componentWillUnmount() {
    this.mounted = false;
  }

  load = () => {
    this.setState({ error: false });
    Promise.resolve().then(() => this.props.load()).then(module => {
      if (this.mounted) {
        this.setState({ Component: module.default });
      }
    }).catch(() => {
      if (this.mounted) {
        this.setState({ error: true });
      }
    });
  };

  render() {
    const { Component, error } = this.state;
    const { intl, load, ...props } = this.props;

    if (error) {
      return <div className='pes-empty' role='status'><p>{intl.formatMessage(messages.standardError)}</p><button type='button' className='pes-button' onClick={this.load}>{intl.formatMessage(messages.retry)}</button></div>;
    }

    return Component ? <Component {...props} /> : <p className='pes-empty' role='status'>{intl.formatMessage(messages.standardLoading)}</p>;
  }

}

export default injectIntl(LazyStandardPicker);
