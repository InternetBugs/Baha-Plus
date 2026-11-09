#ifndef RUNNER_CRASH_DIAGNOSTICS_H_
#define RUNNER_CRASH_DIAGNOSTICS_H_

// Installs process-lifetime, Debug-only native exception logging. Release is a
// no-op. Existing exception-filter behavior is preserved after logging.
void InstallDebugCrashDiagnostics();

#endif  // RUNNER_CRASH_DIAGNOSTICS_H_
