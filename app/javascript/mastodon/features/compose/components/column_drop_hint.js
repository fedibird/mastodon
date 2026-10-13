import React from 'react';
import { FormattedMessage } from 'react-intl';
import Icon from 'mastodon/components/icon';

export default function ColumnDropHint () {
  return (
    <div className='column-drop-target' aria-hidden='true'>
      <span className='column-drop-target__accept'>
        <Icon id='paperclip' />
        <FormattedMessage id='upload_area.column' defaultMessage='Drop files here to attach them' />
      </span>
      <span className='column-drop-target__blocked'>
        <Icon id='ban' />
        <FormattedMessage id='compose_form.upload_blocked' defaultMessage='This posting account can’t attach media here.' />
      </span>
    </div>
  );
}
