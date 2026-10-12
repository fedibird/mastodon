import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import PostingContextBarContainer from '../containers/posting_context_bar_container';
import SearchabilityDropdownContainer from '../containers/searchability_dropdown_container';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const ComposerContextDetails = ({ editing }) => {
  if (editing) {
    return null;
  }

  return (
    <div className='compose-form__context-details' data-testid='posting-context-bar'>
      <PostingContextBarContainer />
      <SearchabilityDropdownContainer />
    </div>
  );
};

ComposerContextDetails.propTypes = {
  editing: PropTypes.bool,
};

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    editing: Boolean(composer && (composer.get('id') || composer.get('scheduled_status_id'))),
  };
};

export default withComposerId(connect(mapStateToProps)(ComposerContextDetails));
