export const toServerSideType = columnType => {
  switch (columnType) {
  case 'home':
  case 'notifications':
  case 'public':
  case 'thread':
  case 'account':
    return columnType;
  default:
    if (columnType && columnType.indexOf('list:') > -1) {
      return 'home';
    }

    return 'public';
  }
};
