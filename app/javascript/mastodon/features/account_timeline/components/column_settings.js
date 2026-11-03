import React, { Fragment } from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl, FormattedMessage } from 'react-intl';
import SettingToggle from '../../notifications/components/setting_toggle';

export default @injectIntl
class ColumnSettings extends React.PureComponent {

  static propTypes = {
    settings: ImmutablePropTypes.map.isRequired,
    advancedMode: PropTypes.bool.isRequired,
    onChange: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  render () {
    const { settings, advancedMode, onChange } = this.props;

    return (
      <div>
        <div className='column-settings__row'>
          <SettingToggle settings={settings} settingPath={['other', 'advancedMode']} onChange={onChange} label={<FormattedMessage id='account.column_settings.advanced_mode' defaultMessage='Advanced mode' />} />
          <SettingToggle settings={settings} settingPath={['other', 'hideHashtagInput']} defaultValue={false} onChange={onChange} label={<FormattedMessage id='account.column_settings.hide_hashtag_input' defaultMessage='Hide hashtag input' />} />
          {advancedMode && (
            <Fragment>
              <span className='column-settings__section'><FormattedMessage id='account.column_settings.advanced_settings' defaultMessage='Advanced settings' /></span>

              <SettingToggle settings={settings} settingPath={['other', 'openPostsFirst']} onChange={onChange} label={<FormattedMessage id='account.column_settings.open_posts_first' defaultMessage='Open posts first' />} />
              <SettingToggle settings={settings} settingPath={['other', 'withoutReblogs']} onChange={onChange} label={<FormattedMessage id='account.column_settings.without_reblogs' defaultMessage='Without boosts' />} />
              <SettingToggle settings={settings} settingPath={['other', 'showPostsInAbout']} onChange={onChange} label={<FormattedMessage id='account.column_settings.show_posts_in_about' defaultMessage='Show posts in about' />} />
              <SettingToggle settings={settings} settingPath={['other', 'hideFeaturedTags']} onChange={onChange} label={<FormattedMessage id='account.column_settings.hide_featured_tags' defaultMessage='Hide featuread tags selection' />} />
              <SettingToggle settings={settings} settingPath={['other', 'hidePostCount']} onChange={onChange} label={<FormattedMessage id='account.column_settings.hide_post_count' defaultMessage='Hide post counters' />} />
              <SettingToggle settings={settings} settingPath={['other', 'hideFollowingCount']} onChange={onChange} label={<FormattedMessage id='account.column_settings.hide_following_count' defaultMessage='Hide following counters' />} />
              <SettingToggle settings={settings} settingPath={['other', 'hideFollowerCount']} onChange={onChange} label={<FormattedMessage id='account.column_settings.hide_follower_count' defaultMessage='Hide follower counters' />} />
              <SettingToggle settings={settings} settingPath={['other', 'hideSubscribingCount']} onChange={onChange} label={<FormattedMessage id='account.column_settings.hide_subscribing_count' defaultMessage='Hide subscribing counters' />} />
            </Fragment>
          )}
        </div>
      </div>
    );
  }

}
