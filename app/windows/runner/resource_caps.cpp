#include "resource_caps.h"

#include <windows.h>

namespace {

constexpr DWORD kCpuRatePercentTimes100 = 8000;  // 80.00%
constexpr double kRamFraction = 0.80;

HANDLE g_job = nullptr;

SIZE_T PhysicalRamBytes() {
  MEMORYSTATUSEX status = {};
  status.dwLength = sizeof(status);
  if (!GlobalMemoryStatusEx(&status) || status.ullTotalPhys == 0) {
    return static_cast<SIZE_T>(4ULL * 1024 * 1024 * 1024);  // 4 GiB fallback
  }
  return static_cast<SIZE_T>(status.ullTotalPhys);
}

}  // namespace

void ApplyOneDropResourceCaps() {
  if (g_job != nullptr) return;

  g_job = CreateJobObjectW(nullptr, L"Local\\AmL.OneDrop.ResourceCaps");
  if (g_job == nullptr) return;

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
  limits.ProcessMemoryLimit =
      static_cast<SIZE_T>(PhysicalRamBytes() * kRamFraction);
  if (!SetInformationJobObject(g_job, JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits))) {
    // Keep going — CPU cap alone is still worth applying.
  }

  JOBOBJECT_CPU_RATE_CONTROL_INFORMATION cpu = {};
  cpu.ControlFlags =
      JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
  cpu.CpuRate = kCpuRatePercentTimes100;
  SetInformationJobObject(g_job, JobObjectCpuRateControlInformation, &cpu,
                          sizeof(cpu));

  // Already-in-a-job (debugger / launcher) fails Assign — ignore.
  AssignProcessToJobObject(g_job, GetCurrentProcess());
}
