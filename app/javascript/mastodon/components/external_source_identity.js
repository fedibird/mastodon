import React from 'react';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import { injectIntl } from 'react-intl';
import Icon from './icon';
import { externalIdentityName } from '../external_presentation';
import { messages } from '../external_presentation/messages';

// The timestamp of a status. An ordinary status keeps its plain anchor. An
// external projection has no status page of its own, so the time links to the
// article when the server verified one and is plain text otherwise; it is never
// an anchor without an href.
export const TimeLink = ({ url, external, className, children }) => {
  if (external && !url) {
    return <span className={className}>{children}</span>;
  }

  return <a href={url} className={className} target='_blank' rel='noopener noreferrer'>{children}</a>;
};

TimeLink.propTypes = {
  url: PropTypes.string,
  external: PropTypes.bool,
  className: PropTypes.string,
  children: PropTypes.node,
};

export class ExternalSourceIcon extends React.PureComponent {

  static propTypes = {
    iconId: PropTypes.string,
    iconUrl: PropTypes.string,
    size: PropTypes.number,
    className: PropTypes.string,
  };

  static defaultProps = {
    iconId: 'external-link',
    size: 36,
  };

  state = {
    failedUrl: null,
  };

  handleError = () => {
    this.setState({ failedUrl: this.props.iconUrl });
  }

  render () {
    const { iconId, iconUrl, size, className } = this.props;
    const showImage = !!iconUrl && this.state.failedUrl !== iconUrl;
    const style = { width: `${size}px`, height: `${size}px`, minWidth: `${size}px`, fontSize: `${Math.round(size * 0.55)}px` };

    return (
      <span className={classNames('account__avatar', 'external-source-icon', className)} style={style} aria-hidden='true'>
        {showImage ? (
          <img
            className='external-source-icon__image'
            src={iconUrl}
            alt=''
            width={size}
            height={size}
            loading='lazy'
            decoding='async'
            referrerPolicy='no-referrer'
            draggable={false}
            onError={this.handleError}
          />
        ) : (
          <Icon id={iconId} className='external-source-icon__glyph' fixedWidth />
        )}
      </span>
    );
  }

}

// The header of an external projection. It names the external source and the
// owner's own private copy; it never shows the owner's avatar or name, never
// links to /accounts/:id, and never offers account actions. Every string is a
// React text child.
export default @injectIntl
class ExternalSourceIdentity extends React.PureComponent {

  static propTypes = {
    identity: PropTypes.shape({
      name: PropTypes.string,
      subtitle: PropTypes.string,
      sourceUrl: PropTypes.string,
      iconUrl: PropTypes.string,
      bylineName: PropTypes.string,
      iconId: PropTypes.string,
    }).isRequired,
    size: PropTypes.number,
    className: PropTypes.string,
    avatarClassName: PropTypes.string,
    showLabel: PropTypes.bool,
    intl: PropTypes.object.isRequired,
  };

  static defaultProps = {
    size: 48,
    showLabel: true,
  };

  render () {
    const { identity, size, className, avatarClassName, showLabel, intl } = this.props;
    const name = externalIdentityName(intl, identity);
    const ownerLabel = intl.formatMessage(messages.ownerLabel);
    const label = identity.subtitle ? `${identity.subtitle} · ${ownerLabel}` : ownerLabel;
    const byline = identity.bylineName && identity.bylineName !== name ? intl.formatMessage(messages.byline, { name: identity.bylineName }) : null;

    const content = (
      <React.Fragment>
        <div className={avatarClassName}>
          <ExternalSourceIcon iconId={identity.iconId} iconUrl={identity.iconUrl} size={size} />
        </div>
        <span className='display-name external-source-identity__text'>
          <bdi><strong className='display-name__html external-source-identity__name'>{name}</strong></bdi>
          {showLabel && <React.Fragment>{' '}<span className='display-name__account external-source-identity__label'>{label}</span></React.Fragment>}
          {byline && <span className='external-source-identity__byline'>{byline}</span>}
        </span>
      </React.Fragment>
    );

    const classes = classNames('external-source-identity', className);

    if (identity.sourceUrl) {
      return (
        <a className={classes} href={identity.sourceUrl} target='_blank' rel='noopener noreferrer' title={intl.formatMessage(messages.openSite, { name })} data-external-source>
          {content}
        </a>
      );
    }

    return (
      <span className={classes} data-external-source>
        {content}
      </span>
    );
  }

}
