#include <unicode/uregex.h>
// ICU reports the failing UTF-16 offset using the same regex grammar as Foundation.
static inline int32_t securityRegexErrorOffset(const uint16_t *pattern, int32_t length) {
    UErrorCode status = U_ZERO_ERROR;
    UParseError error = {0};
    URegularExpression *regex = uregex_open(pattern, length, 0, &error, &status);
    if (regex) uregex_close(regex);
    return U_FAILURE(status) ? error.offset : -1;
}
