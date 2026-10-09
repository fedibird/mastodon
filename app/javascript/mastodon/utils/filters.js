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

    // Unknown ids, including a mix column id such as "mix:<uuid>", land here.
    // A mix contains sources with different filter contexts, so P2 must not
    // pass the mix timeline id to StatusList. Use filterContextForSource.
    return 'public';
  }
};
