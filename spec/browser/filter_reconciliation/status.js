import React from 'react';
import { connect } from 'react-redux';
import { makeGetStatus } from '../../../app/javascript/mastodon/selectors';

// Deterministic content geometry; the selector, list, virtual articles and
// scheduler are production modules. No client-side filter matching here.
export default connect(() => {
  const select = makeGetStatus();
  return (state, props) => ({ status: select(state, props) });
})(({ status, hidden }) => status && !hidden ? (
  <div tabIndex='0' data-status={status.get('id')} style={{ height: status.get('matched_filters') ? 210 : 160, background: '#fff', borderBottom: '1px solid #aaa', boxSizing: 'border-box' }}>
    {status.get('id')} {status.get('matched_filters') ? 'warn' : ''}
  </div>
) : null);
