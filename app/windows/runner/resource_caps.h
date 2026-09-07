#ifndef RUNNER_RESOURCE_CAPS_H_
#define RUNNER_RESOURCE_CAPS_H_

// Hard process caps for One Drop on Windows. Applied once at startup and
// kept for the lifetime of the process (including AirGrab / catch fog).
// CPU: at most 80% of the machine's processor cycles.
// RAM: at most 80% of physical memory for this process.
void ApplyOneDropResourceCaps();

#endif  // RUNNER_RESOURCE_CAPS_H_
