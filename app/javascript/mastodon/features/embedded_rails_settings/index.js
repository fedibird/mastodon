import React from 'react';
import PropTypes from 'prop-types';
import { Link } from 'react-router-dom';
import { connect } from 'react-redux';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';
import { debounce } from 'lodash';
import Column from '../ui/components/column';
import { defaultColumnWidth, isAdministrator } from 'mastodon/initial_state';
import { getEmbeddedScreen, isEmbeddedSettingsUrl } from './registry';
import { bindEmbeddedSettingsNavigation, submitEmbeddedSettings, refreshEmbeddedSettings, settingsFormMethod, pendingSettingsSave } from './requests';

const messages = defineMessages({
  postingStyles: { id: 'embedded_settings.posting_styles', defaultMessage: 'Posting style settings' },
  title: { id: 'embedded_settings.filters', defaultMessage: 'Filter settings' },
});

export class EmbeddedRailsSettings extends React.PureComponent {

  static contextTypes = { router: PropTypes.object };

  static propTypes = {
    screen: PropTypes.string,
    returnTo: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    multiColumn: PropTypes.bool,
  };

  static defaultProps = { screen: 'filters' };

  state = { loading: true, failed: false, saving: false };

  componentDidMount () {
    this.mounted = true;
    if (this.props.screen === 'postingStyles' && !isAdministrator) return;
    this.startTimeout();
    const pending = pendingSettingsSave(this.props.screen, this.props.dispatch);
    if (pending) {
      this.saving = true;
      this.setState({ saving: true });
      pending.finally(() => {
        this.saving = false;
        if (this.mounted) this.setState({ saving: false });
      }).catch(() => {});
    }
  }

  componentWillUnmount () {
    this.mounted = false;
    this.unbindNavigation?.();
    clearTimeout(this.timeout);
    // Passive load refreshes may be flushed; mutation refreshes live in requests.js.
    this.refreshFilters.flush();
    this.refreshFilters.cancel();
  }

  refreshFilters = debounce(() => refreshEmbeddedSettings(this.props.screen, this.props.dispatch), 300);

  startTimeout = () => {
    clearTimeout(this.timeout);
    this.timeout = setTimeout(this.handleError, 15000);
  };

  handleError = () => {
    clearTimeout(this.timeout);
    this.setState({ loading: false, failed: true });
  };

  setFrame = frame => {
    this.frame?.removeEventListener('embedded-settings:ready', this.handleLoad);
    this.frame = frame;
    frame?.addEventListener('embedded-settings:ready', this.handleLoad);
  };

  handleLoad = event => {
    const frame = event.currentTarget;
    this.frame = frame;
    try {
      const url = new URL(frame.contentWindow.location.href);
      const marker = frame.contentDocument.querySelector('meta[name="embedded-rails-settings"]');
      if (!isEmbeddedSettingsUrl(this.props.screen, url, window.location.origin) || marker?.content !== this.props.screen || url.searchParams.get('embedded') !== '1') {
        this.handleError();
        return;
      }
    } catch (error) {
      this.handleError();
      return;
    }

    if (this.boundDocument === frame.contentDocument) return;
    this.unbindNavigation?.();
    this.boundDocument = frame.contentDocument;
    this.unbindNavigation = bindEmbeddedSettingsNavigation(this.props.screen, frame, { onNavigate: this.handleLinkNavigate, onSubmit: this.handleSubmit, onReject: this.handleError });
    this.navigationPending = false;
    clearTimeout(this.timeout);
    this.setState({ loading: false, failed: false });
    this.refreshFilters();
  };

  handleLinkNavigate = url => {
    if (!this.saving && !this.navigationPending) this.handleNavigate(url);
  };

  handleNavigate = url => {
    if (!isEmbeddedSettingsUrl(this.props.screen, url, window.location.origin) || url.searchParams.get('embedded') !== '1') {
      this.handleError(); return;
    }
    this.navigationPending = true;
    this.setState({ loading: true, failed: false });
    this.startTimeout();
    // replace() avoids adding Rails pages to the joint browser history.
    this.frame.contentWindow.location.replace(url.href);
  };

  handleSubmit = (url, body) => {
    if (this.saving || this.navigationPending) return;
    this.saving = true;
    this.setState({ saving: true, loading: true, failed: false });
    this.startTimeout();
    submitEmbeddedSettings(this.props.screen, url, body, this.props.dispatch).then(async response => {
      if (!this.mounted) return;
      const destination = new URL(response.url);
      const renderError = !response.redirected && [409, 422].includes(response.status);
      const method = response.redirected ? 'GET' : settingsFormMethod(body);
      if ((!response.ok && !renderError) || !isEmbeddedSettingsUrl(this.props.screen, destination, window.location.origin, method) || destination.searchParams.get('embedded') !== '1' || (this.props.screen === 'postingStyles' && !response.headers?.get('content-type')?.includes('text/html'))) {
        this.handleError();
        return;
      }
      if (response.redirected) {
        this.handleNavigate(destination);
      } else {
        // Rails validation renders stay on the current new/edit page. Reuse
        // the server-rendered main, retaining this already-CSP-protected head.
        const html = new DOMParser().parseFromString(await response.text(), 'text/html');
        if (!this.mounted) return;
        const main = html.querySelector('main.embedded-settings');
        const marker = html.querySelector('meta[name="embedded-rails-settings"]');
        if (!main || marker?.content !== this.props.screen) {
          this.handleError();
          return;
        }
        const doc = this.frame.contentDocument;
        const replacing = doc.createEvent('Event');
        replacing.initEvent('embedded-settings:before-render', false, false);
        doc.dispatchEvent(replacing);
        doc.querySelector('main.embedded-settings').replaceWith(doc.importNode(main, true));
        doc.title = html.title;
        const rendered = doc.createEvent('Event');
        rendered.initEvent('embedded-settings:render', false, false);
        doc.dispatchEvent(rendered);
        clearTimeout(this.timeout);
        this.setState({ loading: false, failed: false });
      }
    }).catch(() => {
      if (this.mounted) this.handleError();
    }).finally(() => {
      this.saving = false;
      if (this.mounted) this.setState({ saving: false });
    });
  };

  handleRetry = () => {
    if (this.saving) return;
    this.handleNavigate(new URL(getEmbeddedScreen(this.props.screen).embeddedPath, window.location.origin));
  };

  handleBack = event => {
    if (this.props.returnTo && event.button === 0 && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey) {
      event.preventDefault();
      this.context.router.history.goBack();
    }
  };

  render () {
    const { screen, intl, multiColumn, returnTo } = this.props;
    const { loading, failed, saving } = this.state;
    const entry = getEmbeddedScreen(screen);
    if (!entry || (screen === 'postingStyles' && !isAdministrator)) return null;

    const title = intl.formatMessage(screen === 'postingStyles' ? messages.postingStyles : messages.title);

    return (
      <Column icon={entry.icon} heading={title} columnWidth={defaultColumnWidth}>
        <div className='embedded-rails-settings'>
          <nav className='embedded-rails-settings__navigation'>
            <Link to={returnTo || (multiColumn ? '/getting-started' : '/timelines/home')} onClick={this.handleBack}>
              <FormattedMessage id='column_back_button.label' defaultMessage='Back' />
            </Link>
            <a href={entry.path} target='_blank' rel='noopener noreferrer'>
              <FormattedMessage id='embedded_settings.open' defaultMessage='Open in a new tab' />
            </a>
          </nav>
          {saving && <p><FormattedMessage id='embedded_settings.saving' defaultMessage='Saving settings… You can leave this column; changes will be synchronized when the request finishes.' /></p>}
          {loading && <p role='status'><FormattedMessage id='embedded_settings.loading' defaultMessage='Loading settings…' /></p>}
          {failed && <div role='alert'>
            <p><FormattedMessage id='embedded_settings.failed' defaultMessage='Settings could not be loaded. Open them in a new tab to check your connection or sign in again, then retry.' /></p>
            <button type='button' className='button' onClick={this.handleRetry} disabled={saving}><FormattedMessage id='retry' defaultMessage='Try again' /></button>
          </div>}
          <iframe ref={this.setFrame} src={entry.embeddedPath} title={title} aria-busy={loading || saving} tabIndex={loading || saving ? -1 : 0} onLoad={this.handleLoad} onError={this.handleError} hidden={failed} />
        </div>
      </Column>
    );
  }

}

export default connect()(injectIntl(EmbeddedRailsSettings));
