import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl, FormattedMessage } from 'react-intl';
import SettingToggle from '../../notifications/components/setting_toggle';

export default @injectIntl
class ColumnSettings extends React.PureComponent {

  static propTypes = {
    settings: ImmutablePropTypes.map.isRequired,
    onChange: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    columnId: PropTypes.string,
  };

  render () {
    const { settings, onChange } = this.props;

    return (
      <div>
        <div className='column-settings__row'>
          <SettingToggle settings={settings} settingPath={['other', 'sortByPostDate']} defaultValue={false} onChange={onChange} label={<FormattedMessage id='column.saved_sort_by_post_date' defaultMessage='Order by post date' />} />
        </div>
        <div className='column-settings__row'>
          <SettingToggle settings={settings} settingPath={['other', 'onlyMedia']} exclusiveSettingPaths={[['other', 'withoutMedia']]} onChange={onChange} label={<FormattedMessage id='community.column_settings.media_only' defaultMessage='Media only' />} />
          <SettingToggle settings={settings} settingPath={['other', 'withoutMedia']} exclusiveSettingPaths={[['other', 'onlyMedia']]} onChange={onChange} label={<FormattedMessage id='community.column_settings.without_media' defaultMessage='Without media' />} />
        </div>
      </div>
    );
  }

}
