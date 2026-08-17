#ifndef CROSSDESKTOP_CORE_H
#define CROSSDESKTOP_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t cdr_core_abi_version(void);
uint32_t cdr_core_protocol_major_version(void);
uint64_t cdr_core_feature_flags(void);

#ifdef __cplusplus
}
#endif

#endif
