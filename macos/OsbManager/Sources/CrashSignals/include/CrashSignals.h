#ifndef CRASH_SIGNALS_H
#define CRASH_SIGNALS_H

#ifdef __cplusplus
extern "C" {
#endif

int crash_signals_install(void);
void crash_signals_set_descriptor(int descriptor);
int crash_signals_descriptor(void);
void crash_signals_uninstall(void);

#ifdef __cplusplus
}
#endif

#endif
