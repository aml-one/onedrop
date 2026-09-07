/// Per-file cap. Bodies stream to disk; 7 GiB covers a long 4K clip or an ISO.
const dropMaxFileBytes = 7 * 1024 * 1024 * 1024;

const dropMaxFileLabel = '7 GB';

const dropMaxFiles = 50;

String dropTooLargeMessage() =>
    'File too large for One Drop (max $dropMaxFileLabel)';
