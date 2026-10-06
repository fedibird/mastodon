import React from 'react';
import PropTypes from 'prop-types';

import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const ComposerIdContext = React.createContext(PRIMARY_COMPOSER_ID);

export const ComposerProvider = ({ composerId, children }) => (
  <ComposerIdContext.Provider value={composerId}>
    {children}
  </ComposerIdContext.Provider>
);

ComposerProvider.propTypes = {
  composerId: PropTypes.string,
  children: PropTypes.node,
};

ComposerProvider.defaultProps = {
  composerId: PRIMARY_COMPOSER_ID,
};

export const withComposerId = WrappedComponent => {
  const WithComposerId = props => (
    <ComposerIdContext.Consumer>
      {composerId => (
        <WrappedComponent
          {...props}
          composerId={composerId}
        />
      )}
    </ComposerIdContext.Consumer>
  );

  WithComposerId.displayName = `withComposerId(${WrappedComponent.displayName || WrappedComponent.name || 'Component'})`;

  return WithComposerId;
};
