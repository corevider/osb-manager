#include "CrashSignals.h"

#include <signal.h>
#include <string.h>
#include <unistd.h>

static const int handled_signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE};
static const int handled_count = (int)(sizeof(handled_signals) / sizeof(handled_signals[0]));
static struct sigaction previous_actions[NSIG];
static volatile sig_atomic_t signal_descriptor = -1;
static volatile sig_atomic_t installed = 0;

static void crash_signal_handler(int number) {
  int descriptor = signal_descriptor;
  if (descriptor >= 0) {
    unsigned char byte = (unsigned char)number;
    ssize_t written = write(descriptor, &byte, 1);
    (void)written;
  }
  if (number > 0 && number < NSIG) {
    sigaction(number, &previous_actions[number], NULL);
  }
  raise(number);
}

int crash_signals_install(void) {
  if (installed) {
    return 1;
  }
  for (int index = 0; index < handled_count; ++index) {
    int number = handled_signals[index];
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = crash_signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_ONSTACK;
    if (sigaction(number, &action, &previous_actions[number]) != 0) {
      return 0;
    }
  }
  installed = 1;
  return 1;
}

void crash_signals_set_descriptor(int descriptor) {
  signal_descriptor = descriptor;
}

int crash_signals_descriptor(void) {
  return signal_descriptor;
}

void crash_signals_uninstall(void) {
  if (!installed) {
    return;
  }
  signal_descriptor = -1;
  for (int index = 0; index < handled_count; ++index) {
    int number = handled_signals[index];
    sigaction(number, &previous_actions[number], NULL);
  }
  installed = 0;
}
