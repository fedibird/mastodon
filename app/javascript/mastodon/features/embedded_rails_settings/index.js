import React from 'react';
import PropTypes from 'prop-types';
import { Link } from 'react-router-dom';
import { connect } from 'react-redux';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';
import { debounce } from 'lodash';
import Column from '../ui/components/column';
import { fetchFilters } from 'mastodon/actions/filters';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { getEmbeddedScreen, isFilterSettingsUrl } from './registry';

const messages = defineMessages({
  title: { id: 'embedded_settings.filters', defaultMessage: 'Filter settings' },
});

export class EmbeddedRailsSettings extends React.PureComponent {

  static propTypes = {
    screen: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    multiColumn: PropTypes.bool,
  };

  static defaultProps = { screen: 'filters' };

  state = { loading: true, failed: false, attempt: 0 };

  componentDidMount () {
    this.startTimeout();
  }

  componentWillUnmount () {
    clearTimeout(this.timeout);
    // A save followed immediately by closing the column must still refresh.
    this.refreshFilters.flush();
    this.refreshFilters.cancel();
  }

  refreshFilters = debounce(() => this.props.dispatch(fetchFilters()), 300);

  startTimeout = () => {
    clearTimeout(this.timeout);
    this.timeout = setTimeout(this.handleError, 15000);
  };

  handleError = () => {
    clearTimeout(this.timeout);
    this.setState({ loading: false, failed: true });
  };

  handleLoad = event => {
    const frame = event.currentTarget;
    try {
      const url = new URL(frame.contentWindow.location.href);
      const marker = frame.contentDocument.querySelector('meta[name="embedded-rails-settings"]');
      if (!isFilterSettingsUrl(url, window.location.origin) || marker?.content !== this.props.screen || url.searchParams.get('embedded') !== '1') {
        this.handleError();
        return;
      }
    } catch (error) {
      this.handleError();
      return;
    }

    clearTimeout(this.timeout);
    this.setState({ loading: false, failed: false });
    this.refreshFilters();
  };

  handleRetry = () => {
    this.setState(({ attempt }) => ({ loading: true, failed: false, attempt: attempt + 1 }));
    this.startTimeout();
  };

  render () {
    const { screen, intl, multiColumn } = this.props;
    const { loading, failed, attempt } = this.state;
    const entry = getEmbeddedScreen(screen);
    if (!entry) return null;

    const title = intl.formatMessage(messages.title);

    return (
      <Column icon='filter' heading={title} columnWidth={defaultColumnWidth}>
        <div className='embedded-rails-settings'>
          <nav className='embedded-rails-settings__navigation'>
            <Link to={multiColumn ? '/getting-started' : '/timelines/home'}>
              <FormattedMessage id='column_back_button.label' defaultMessage='Back' />
            </Link>
            <a href={entry.path} target='_blank' rel='noopener noreferrer'>
              <FormattedMessage id='embedded_settings.open' defaultMessage='Open in a new tab' />
            </a>
          </nav>
          {loading && <p role='status'><FormattedMessage id='embedded_settings.loading' defaultMessage='Loading settings…' /></p>}
          {failed && <div role='alert'>
            <p><FormattedMessage id='embedded_settings.failed' defaultMessage='Settings could not be loaded. Open them in a new tab to check your connection or sign in again, then retry.' /></p>
            <button type='button' className='button' onClick={this.handleRetry}><FormattedMessage id='retry' defaultMessage='Try again' /></button>
          </div>}
          <iframe key={attempt} src={entry.embeddedPath} title={title} onLoad={this.handleLoad} onError={this.handleError} hidden={failed} />
        </div>
      </Column>
    );
  }

}

export default connect()(injectIntl(EmbeddedRailsSettings));
