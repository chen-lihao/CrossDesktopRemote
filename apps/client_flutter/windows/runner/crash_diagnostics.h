#ifndef RUNNER_CRASH_DIAGNOSTICS_H_
#define RUNNER_CRASH_DIAGNOSTICS_H_

// Installs a process-local unhandled-exception filter that writes a bounded
// minidump to the current user's LocalAppData directory. Dumps never leave the
// machine automatically and intentionally exclude full process memory.
void InstallCrashDiagnostics();

#endif  // RUNNER_CRASH_DIAGNOSTICS_H_
